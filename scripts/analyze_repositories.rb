#!/usr/bin/env ruby

require 'octokit'
require 'json'
require 'tmpdir'
require 'fileutils'

# Load .env file for local development
begin
  require 'dotenv'
  Dotenv.load
rescue LoadError
  # dotenv not available, skip loading (e.g., in GitHub Actions)
end

class RepositoryAnalyzer
  def initialize
    @client = Octokit::Client.new(access_token: ENV['GH_TOKEN'])
    @client.auto_paginate = true
    @repositories = parse_repositories_env
    @max_threads = ENV['MAX_THREADS']&.to_i || 4  # Default to 4 threads
    @cache_hours = ENV['CACHE_HOURS']&.to_i || 3  # Default to 3 hours
    @include_private = ENV['INCLUDE_PRIVATE_REPOS']&.downcase == 'true'  # Default to false
    @thread_mutex = Mutex.new  # For thread-safe operations
    @error_repositories = []  # Track repositories with errors
    @error_mutex = Mutex.new  # For thread-safe error tracking
  end

  def analyze_all
    puts "Starting repository analysis with #{@max_threads} threads..."
    puts "Including private repositories: #{@include_private ? 'Yes' : 'No'}"
    puts "Repositories to analyze: #{@repositories.join(', ')}"

    # First, collect all repository names to analyze
    all_repos = []
    @repositories.each do |repo_spec|
      if repo_spec.include?('/')
        # Specific repository: "owner/repo"
        all_repos << repo_spec
      else
        # All repositories for user/org
        user_repos = get_user_repositories(repo_spec)
        all_repos.concat(user_repos)
      end
    end

    puts "Total repositories found: #{all_repos.length}"

    # Add repositories from error report for retry
    error_repos = get_repositories_from_error_report
    if error_repos.any?
      puts "Found #{error_repos.length} repositories from previous error report for retry"
      all_repos.concat(error_repos)
      all_repos.uniq!
      puts "Total repositories after adding error retries: #{all_repos.length}"
    end

    # Filter out cached repositories
    repos_to_analyze = filter_cached_repositories(all_repos)
    puts "Repositories to analyze after cache check: #{repos_to_analyze.length}"
    puts "Skipped #{all_repos.length - repos_to_analyze.length} repositories (recently cached)"

    if repos_to_analyze.empty?
      puts "All repositories are recently cached. Nothing to analyze."
      return
    end

    # Process repositories in parallel
    process_repositories_parallel(repos_to_analyze)

    # Generate error report
    generate_error_report

    # Clean up successful repositories from error report
    clean_up_error_report
  end

  private

  def get_repositories_from_error_report
    error_report_path = File.join('statistics', 'error_report.json')

    return [] unless File.exist?(error_report_path)

    begin
      error_data = JSON.parse(File.read(error_report_path))
      error_repos = error_data['errors'] || []

      # Extract repository names and filter out user/org level errors
      repo_names = error_repos
        .map { |error| error['repository'] }
        .reject { |repo| repo.end_with?('/*') }  # Skip user/org level errors
        .uniq

      puts "Loading #{repo_names.length} repositories from previous error report for retry"
      return repo_names

    rescue JSON::ParserError => e
      puts "Warning: Could not parse error report (#{error_report_path}): #{e.message}"
      return []
    rescue => e
      puts "Warning: Error reading error report (#{error_report_path}): #{e.message}"
      return []
    end
  end

  def generate_error_report
    if @error_repositories.empty?
      puts "\n✅ All repositories analyzed successfully!"

      # If no new errors but error report file exists, show it was cleaned up
      error_report_path = File.join('statistics', 'error_report.json')
      if File.exist?(error_report_path)
        puts "Previous error report will be cleaned up."
      end
      return
    end

    puts "\n⚠️  Error Report:"
    puts "#{@error_repositories.length} repositories encountered errors:"

    # Save detailed error report to file
    error_report_path = File.join('statistics', 'error_report.json')
    error_summary_path = File.join('statistics', 'error_summary.md')

    error_data = {
      timestamp: Time.now.iso8601,
      total_errors: @error_repositories.length,
      errors: @error_repositories
    }

    File.write(error_report_path, JSON.pretty_generate(error_data))
    generate_error_summary_markdown(error_summary_path, error_data)

    puts "Detailed error report saved to: #{error_report_path}"
    puts "Error summary saved to: #{error_summary_path}"

    # Print summary to console
    error_types = @error_repositories.group_by { |error| error[:error_type] }
    error_types.each do |type, errors|
      puts "  #{type}: #{errors.length} repositories"
      errors.first(3).each { |error| puts "    - #{error[:repository]}" }
      puts "    ... and #{errors.length - 3} more" if errors.length > 3
    end
  end

  def clean_up_error_report
    error_report_path = File.join('statistics', 'error_report.json')
    error_summary_path = File.join('statistics', 'error_summary.md')

    # If no errors occurred in this run, remove error report files
    if @error_repositories.empty?
      if File.exist?(error_report_path)
        File.delete(error_report_path)
        puts "✅ Removed previous error report (all repositories now successful)"
      end

      if File.exist?(error_summary_path)
        File.delete(error_summary_path)
        puts "✅ Removed previous error summary"
      end
    else
      # If there are still errors, show which ones were resolved
      previous_error_repos = get_error_repository_names
      current_error_repos = @error_repositories.map { |e| e[:repository] }
      resolved_repos = previous_error_repos - current_error_repos

      if resolved_repos.any?
        puts "\n✅ Resolved errors for #{resolved_repos.length} repositories:"
        resolved_repos.first(5).each { |repo| puts "  - #{repo}" }
        puts "  ... and #{resolved_repos.length - 5} more" if resolved_repos.length > 5
      end
    end
  end

  def generate_error_summary_markdown(filepath, error_data)
    content = <<~MARKDOWN
      # Repository Analysis Error Report

      Generated: #{error_data[:timestamp]}

      ## Summary

      - **Total Errors**: #{error_data[:total_errors]}

      ## Error Details

    MARKDOWN

    error_types = error_data[:errors].group_by { |error| error[:error_type] }
    error_types.each do |type, errors|
      content += "### #{type} (#{errors.length} repositories)\n\n"
      content += "| Repository | Error Message | Timestamp |\n"
      content += "|------------|---------------|----------|\n"

      errors.each do |error|
        timestamp = error[:timestamp].split('T')[1]&.split('.')[0] || error[:timestamp]
        message = error[:error_message].gsub('|', '\\|')  # Escape pipes for markdown
        content += "| #{error[:repository]} | #{message} | #{timestamp} |\n"
      end
      content += "\n"
    end

    File.write(filepath, content)
  end

  def record_repository_error(repository, error, error_type = nil)
    # Determine error type from the error message
    error_type ||= categorize_error(error)

    error_info = {
      repository: repository,
      error_type: error_type,
      error_message: error.message,
      timestamp: Time.now.iso8601,
      thread_id: Thread.current.object_id
    }

    @error_mutex.synchronize do
      @error_repositories << error_info
    end
  end

  def categorize_error(error)
    case error
    when Octokit::NotFound
      "Not Found (404)"
    when Octokit::Unauthorized
      "Unauthorized (401)"
    when Octokit::Forbidden
      if error.message.include?('rate limit')
        "Rate Limited (403)"
      elsif error.message.include?('access blocked')
        "Access Blocked (403)"
      else
        "Forbidden (403)"
      end
    when Octokit::UnprocessableEntity
      "Unprocessable Entity (422)"
    when Octokit::InternalServerError
      "Internal Server Error (500)"
    when Octokit::BadGateway
      "Bad Gateway (502)"
    when Octokit::ServiceUnavailable
      "Service Unavailable (503)"
    when Net::TimeoutError, Timeout::Error
      "Timeout Error"
    when JSON::ParserError
      "JSON Parse Error"
    else
      "Other Error (#{error.class.name})"
    end
  end

  def filter_cached_repositories(repo_names)
    repos_to_analyze = []
    current_time = Time.now
    error_repos = get_error_repository_names

    repo_names.each do |repo_name|
      filename = repo_name.gsub('/', '_') + '.json'
      filepath = File.join('statistics', filename)

      # Force re-analysis if repository was in previous error report
      if error_repos.include?(repo_name)
        repos_to_analyze << repo_name
        puts "  Adding #{repo_name} for retry (was in error report)"
      elsif should_analyze_repository?(repo_name, filepath, current_time)
        repos_to_analyze << repo_name
      else
        puts "  Skipping #{repo_name} (recently cached within #{@cache_hours} hours)"
      end
    end

    repos_to_analyze
  end

  def get_error_repository_names
    error_report_path = File.join('statistics', 'error_report.json')
    return [] unless File.exist?(error_report_path)

    begin
      error_data = JSON.parse(File.read(error_report_path))
      error_repos = error_data['errors'] || []

      repo_names = error_repos
        .map { |error| error['repository'] }
        .reject { |repo| repo.end_with?('/*') }  # Skip user/org level errors
        .uniq

      return repo_names
    rescue
      return []
    end
  end

  def should_analyze_repository?(repo_name, filepath, current_time)
    # If file doesn't exist, we need to analyze
    return true unless File.exist?(filepath)

    begin
      # Read the existing file to check analyzed_at timestamp
      existing_data = JSON.parse(File.read(filepath))
      analyzed_at = existing_data['analyzed_at']

      return true if analyzed_at.nil?

      # Parse the timestamp and check if it's within cache period
      begin
        # Try to parse ISO 8601 format manually for better compatibility
        if analyzed_at.match(/(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/)
          year, month, day, hour, min, sec = $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i
          analyzed_time = Time.new(year, month, day, hour, min, sec)
        else
          # Fallback: assume it needs re-analysis if format is unknown
          return true
        end

        cache_threshold = current_time - (@cache_hours * 60 * 60)  # Convert hours to seconds

        # If analyzed_time is older than cache threshold, we need to re-analyze
        analyzed_time < cache_threshold
      rescue => e
        # If we can't parse the time, assume we need to re-analyze
        true
      end

    rescue JSON::ParserError, ArgumentError => e
      # If we can't parse the file or timestamp, re-analyze to be safe
      puts "  Warning: Could not parse existing data for #{repo_name}: #{e.message}"
      true
    rescue => e
      # Any other error, re-analyze to be safe
      puts "  Warning: Error checking cache for #{repo_name}: #{e.message}"
      true
    end
  end

  def parse_repositories_env
    repositories_env = ENV['REPOSITORIES'] || ''
    repositories_env.split(',').map(&:strip).reject(&:empty?)
  end

  def get_user_repositories(username)
    repo_type = @include_private ? 'all' : 'public'
    puts "Fetching repositories for #{username} (type: #{repo_type})..."

    begin
      repos = @client.repositories(username, type: repo_type)

      # Filter out private repos if not including them
      unless @include_private
        repos = repos.select { |repo| !repo.private }
      end

      repo_names = repos.map { |repo| "#{repo.owner.login}/#{repo.name}" }
      puts "  Found #{repo_names.length} repositories for #{username}"
      return repo_names
    rescue Octokit::NotFound => e
      record_repository_error("#{username}/*", e, "User/Org Not Found")
      puts "User/organization '#{username}' not found"
      return []
    rescue Octokit::Forbidden => e
      record_repository_error("#{username}/*", e, "Access Forbidden to User/Org")
      puts "Access forbidden for #{username}: #{e.message}"
      return []
    rescue => e
      record_repository_error("#{username}/*", e, "User/Org Fetch Error")
      puts "Error fetching repositories for #{username}: #{e.message}"
      return []
    end
  end

  def process_repositories_parallel(repo_names)
    completed = 0
    total = repo_names.length

    # Split repositories into chunks for each thread
    repo_chunks = repo_names.each_slice((repo_names.length.to_f / @max_threads).ceil).to_a

    threads = repo_chunks.map.with_index do |chunk, thread_id|
      Thread.new do
        chunk.each do |repo_name|
          begin
            analyze_repository_with_client(repo_name, thread_id)

            @thread_mutex.synchronize do
              completed += 1
              puts "Progress: #{completed}/#{total} repositories completed"
            end
          rescue => e
            @thread_mutex.synchronize do
              puts "Error in thread #{thread_id} processing #{repo_name}: #{e.message}"
            end
          end
        end
      end
    end

    # Wait for all threads to complete
    threads.each(&:join)
    puts "All repositories analyzed!"
  end

  def analyze_user_repositories(username)
    puts "Fetching repositories for #{username}..."

    begin
      repos = @client.repositories(username, type: 'all')
      repos.each do |repo|
        analyze_repository("#{repo.owner.login}/#{repo.name}")
      end
    rescue Octokit::NotFound
      puts "User/organization '#{username}' not found"
    rescue => e
      puts "Error fetching repositories for #{username}: #{e.message}"
    end
  end

  def analyze_repository_with_client(repo_name, thread_id)
    # Create a separate client for each thread to avoid conflicts
    thread_client = Octokit::Client.new(access_token: ENV['GH_TOKEN'])
    thread_client.auto_paginate = true

    @thread_mutex.synchronize do
      puts "[Thread #{thread_id}] Analyzing repository: #{repo_name}"
    end

    begin
      repo = thread_client.repository(repo_name)

      # Skip if repository is empty or archived
      if repo.size == 0
        @thread_mutex.synchronize do
          puts "[Thread #{thread_id}] Skipping empty repository: #{repo_name}"
        end
        return
      end

      statistics = {
        repository: repo_name,
        owner: repo.owner.login,
        name: repo.name,
        description: repo.description,
        language: repo.language,
        created_at: repo.created_at,
        updated_at: repo.updated_at,
        size: repo.size,
        stargazers_count: repo.stargazers_count,
        watchers_count: repo.watchers_count,
        forks_count: repo.forks_count,
        open_issues_count: repo.open_issues_count,
        analyzed_at: Time.now.iso8601,
        commit_statistics: analyze_commits_with_client(repo_name, thread_client, thread_id),
        language_statistics: analyze_languages_with_client(repo_name, thread_client, thread_id)
      }

      save_statistics_thread_safe(repo_name, statistics, thread_id)

    rescue Octokit::NotFound => e
      record_repository_error(repo_name, e)
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}] Repository '#{repo_name}' not found or not accessible"
      end
    rescue Octokit::Forbidden => e
      record_repository_error(repo_name, e)
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}] Access forbidden for #{repo_name}: #{e.message}"
      end
    rescue Octokit::Unauthorized => e
      record_repository_error(repo_name, e)
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}] Unauthorized access for #{repo_name}: #{e.message}"
      end
    rescue => e
      record_repository_error(repo_name, e)
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}] Error analyzing repository #{repo_name}: #{e.message}"
      end
    end
  end

  def analyze_repository(repo_name)
    puts "Analyzing repository: #{repo_name}"

    begin
      repo = @client.repository(repo_name)

      # Skip if repository is empty or archived
      if repo.size == 0
        puts "Skipping empty repository: #{repo_name}"
        return
      end

      statistics = {
        repository: repo_name,
        owner: repo.owner.login,
        name: repo.name,
        description: repo.description,
        language: repo.language,
        created_at: repo.created_at,
        updated_at: repo.updated_at,
        size: repo.size,
        stargazers_count: repo.stargazers_count,
        watchers_count: repo.watchers_count,
        forks_count: repo.forks_count,
        open_issues_count: repo.open_issues_count,
        analyzed_at: Time.now.iso8601,
        commit_statistics: analyze_commits(repo_name),
        language_statistics: analyze_languages(repo_name)
      }

      save_statistics(repo_name, statistics)

    rescue Octokit::NotFound
      puts "Repository '#{repo_name}' not found or not accessible"
    rescue => e
      puts "Error analyzing repository #{repo_name}: #{e.message}"
    end
  end

  def analyze_commits_with_client(repo_name, client, thread_id)
    @thread_mutex.synchronize do
      puts "[Thread #{thread_id}]   Analyzing commits for #{repo_name}..."
    end

    commit_stats = Hash.new do |h, k|
      h[k] = {
        commits: 0,
        additions: 0,
        deletions: 0,
        email: nil,
        languages: Hash.new { |lang_h, lang_k| lang_h[lang_k] = { additions: 0, deletions: 0, commits: 0 } }
      }
    end

    begin
      # Get all commits (GitHub API limits to 250 per page)
      commits = client.commits(repo_name)

      commits.each_with_index do |commit, index|
        author = commit.commit.author.name
        author_email = commit.commit.author.email

        # Get detailed commit info for line changes
        detailed_commit = client.commit(repo_name, commit.sha)

        commit_stats[author][:commits] += 1
        commit_stats[author][:additions] += detailed_commit.stats.additions || 0
        commit_stats[author][:deletions] += detailed_commit.stats.deletions || 0
        commit_stats[author][:email] = author_email

        # Analyze file changes by language
        if detailed_commit.files
          detailed_commit.files.each do |file|
            language = detect_language_from_filename(file.filename)
            next if language.nil?

            file_additions = file.additions || 0
            file_deletions = file.deletions || 0

            commit_stats[author][:languages][language][:additions] += file_additions
            commit_stats[author][:languages][language][:deletions] += file_deletions
            commit_stats[author][:languages][language][:commits] += 1 if file_additions > 0 || file_deletions > 0
          end
        end

        # Add a small delay to avoid rate limiting (reduced for parallel processing)
        sleep(0.05) if index % 20 == 0
      end

    rescue => e
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}]   Error analyzing commits: #{e.message}"
      end
    end

    # Convert nested hashes to regular hashes for JSON serialization
    commit_stats.each do |author, stats|
      stats[:languages] = stats[:languages].to_h do |lang, lang_stats|
        [lang, lang_stats.to_h]
      end
    end

    commit_stats.to_h
  end

  def analyze_commits(repo_name)
    puts "  Analyzing commits for #{repo_name}..."

    commit_stats = Hash.new do |h, k|
      h[k] = {
        commits: 0,
        additions: 0,
        deletions: 0,
        email: nil,
        languages: Hash.new { |lang_h, lang_k| lang_h[lang_k] = { additions: 0, deletions: 0, commits: 0 } }
      }
    end

    begin
      # Get all commits (GitHub API limits to 250 per page)
      commits = @client.commits(repo_name)

      commits.each_with_index do |commit, index|
        author = commit.commit.author.name
        author_email = commit.commit.author.email

        # Get detailed commit info for line changes
        detailed_commit = @client.commit(repo_name, commit.sha)

        commit_stats[author][:commits] += 1
        commit_stats[author][:additions] += detailed_commit.stats.additions || 0
        commit_stats[author][:deletions] += detailed_commit.stats.deletions || 0
        commit_stats[author][:email] = author_email

        # Analyze file changes by language
        if detailed_commit.files
          detailed_commit.files.each do |file|
            language = detect_language_from_filename(file.filename)
            next if language.nil?

            file_additions = file.additions || 0
            file_deletions = file.deletions || 0

            commit_stats[author][:languages][language][:additions] += file_additions
            commit_stats[author][:languages][language][:deletions] += file_deletions
            commit_stats[author][:languages][language][:commits] += 1 if file_additions > 0 || file_deletions > 0
          end
        end

        # Add a small delay to avoid rate limiting
        sleep(0.1) if index % 10 == 0
      end

    rescue => e
      puts "  Error analyzing commits: #{e.message}"
    end

    # Convert nested hashes to regular hashes for JSON serialization
    commit_stats.each do |author, stats|
      stats[:languages] = stats[:languages].to_h do |lang, lang_stats|
        [lang, lang_stats.to_h]
      end
    end

    commit_stats.to_h
  end

  def detect_language_from_filename(filename)
    extension = File.extname(filename).downcase

    language_map = {
      '.rb' => 'Ruby',
      '.py' => 'Python',
      '.js' => 'JavaScript',
      '.ts' => 'TypeScript',
      '.jsx' => 'JavaScript',
      '.tsx' => 'TypeScript',
      '.java' => 'Java',
      '.c' => 'C',
      '.cpp' => 'C++',
      '.cc' => 'C++',
      '.cxx' => 'C++',
      '.h' => 'C',
      '.hpp' => 'C++',
      '.cs' => 'C#',
      '.php' => 'PHP',
      '.go' => 'Go',
      '.rs' => 'Rust',
      '.swift' => 'Swift',
      '.kt' => 'Kotlin',
      '.scala' => 'Scala',
      '.clj' => 'Clojure',
      '.hs' => 'Haskell',
      '.ml' => 'OCaml',
      '.fs' => 'F#',
      '.dart' => 'Dart',
      '.lua' => 'Lua',
      '.r' => 'R',
      '.m' => 'Objective-C',
      '.mm' => 'Objective-C++',
      '.pl' => 'Perl',
      '.sh' => 'Shell',
      '.bash' => 'Shell',
      '.zsh' => 'Shell',
      '.fish' => 'Shell',
      '.ps1' => 'PowerShell',
      '.sql' => 'SQL',
      '.html' => 'HTML',
      '.htm' => 'HTML',
      '.css' => 'CSS',
      '.scss' => 'SCSS',
      '.sass' => 'Sass',
      '.less' => 'Less',
      '.xml' => 'XML',
      '.json' => 'JSON',
      '.yaml' => 'YAML',
      '.yml' => 'YAML',
      '.toml' => 'TOML',
      '.ini' => 'INI',
      '.cfg' => 'Config',
      '.conf' => 'Config',
      '.dockerfile' => 'Dockerfile',
      '.md' => 'Markdown',
      '.txt' => 'Text',
      '.vue' => 'Vue',
      '.svelte' => 'Svelte',
      '.elm' => 'Elm',
      '.ex' => 'Elixir',
      '.exs' => 'Elixir',
      '.erl' => 'Erlang',
      '.hrl' => 'Erlang',
      '.nim' => 'Nim',
      '.crystal' => 'Crystal',
      '.cr' => 'Crystal',
      '.zig' => 'Zig'
    }

    # Special filename checks
    case File.basename(filename).downcase
    when 'dockerfile'
      return 'Dockerfile'
    when 'makefile'
      return 'Makefile'
    when 'gemfile', 'rakefile'
      return 'Ruby'
    when 'package.json', 'package-lock.json'
      return 'JSON'
    when 'composer.json', 'composer.lock'
      return 'JSON'
    when 'cargo.toml', 'cargo.lock'
      return 'TOML'
    end

    language_map[extension]
  end

  def analyze_languages_with_client(repo_name, client, thread_id)
    @thread_mutex.synchronize do
      puts "[Thread #{thread_id}]   Analyzing languages for #{repo_name}..."
    end

    begin
      languages = client.languages(repo_name)

      # Handle nil or empty languages
      if languages.nil? || languages.empty?
        @thread_mutex.synchronize do
          puts "[Thread #{thread_id}]     No language data available"
        end
        return {}
      end

      # Safe calculation of total bytes
      language_values = languages.values || []
      total_bytes = language_values.inject(0) { |sum, bytes| sum + (bytes || 0) }

      language_stats = {}
      languages.each do |language, bytes|
        bytes = bytes || 0
        percentage = total_bytes > 0 ? (bytes.to_f / total_bytes * 100).round(2) : 0
        language_stats[language] = {
          bytes: bytes,
          percentage: percentage
        }
      end

      language_stats
    rescue => e
      @thread_mutex.synchronize do
        puts "[Thread #{thread_id}]   Error analyzing languages: #{e.message}"
      end
      {}
    end
  end

  def save_statistics_thread_safe(repo_name, statistics, thread_id)
    filename = repo_name.gsub('/', '_') + '.json'
    filepath = File.join('statistics', filename)

    @thread_mutex.synchronize do
      File.write(filepath, JSON.pretty_generate(statistics))
      puts "[Thread #{thread_id}]   Statistics saved to #{filepath}"
    end
  end

  def analyze_languages(repo_name)
    puts "  Analyzing languages for #{repo_name}..."

    begin
      languages = @client.languages(repo_name)

      # Handle nil or empty languages
      if languages.nil? || languages.empty?
        puts "    No language data available"
        return {}
      end

      # Safe calculation of total bytes
      language_values = languages.values || []
      total_bytes = language_values.inject(0) { |sum, bytes| sum + (bytes || 0) }

      language_stats = {}
      languages.each do |language, bytes|
        bytes = bytes || 0
        percentage = total_bytes > 0 ? (bytes.to_f / total_bytes * 100).round(2) : 0
        language_stats[language] = {
          bytes: bytes,
          percentage: percentage
        }
      end

      language_stats
    rescue => e
      puts "  Error analyzing languages: #{e.message}"
      {}
    end
  end

  def save_statistics(repo_name, statistics)
    filename = repo_name.gsub('/', '_') + '.json'
    filepath = File.join('statistics', filename)

    File.write(filepath, JSON.pretty_generate(statistics))
    puts "  Statistics saved to #{filepath}"
  end
end

# Run the analyzer
if __FILE__ == $0
  analyzer = RepositoryAnalyzer.new
  analyzer.analyze_all
end
