#!/usr/bin/env ruby

require 'json'
require 'fileutils'

# Load .env file for local development
begin
  require 'dotenv'
  Dotenv.load
rescue LoadError
  # dotenv not available, skip loading (e.g., in GitHub Actions)
end

class StatisticsAggregator
  def initialize
    # Support both USERNAME (legacy) and USERNAMES (new)
    usernames_env = ENV['USERNAMES'] || ENV['USERNAME']
    @usernames = parse_usernames(usernames_env)
    @primary_username = @usernames.first if @usernames.any?
    @statistics_dir = 'statistics'
    @aggregated_stats = {
      usernames: @usernames,
      primary_username: @primary_username,
      total_repositories: 0,
      total_commits: 0,
      total_additions: 0,
      total_deletions: 0,
      languages: Hash.new { |h, k| h[k] = { commits: 0, additions: 0, deletions: 0, bytes: 0 } },
      repositories: [],
      commit_timeline: {},
      generated_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
    }
  end

  def aggregate
    if @usernames.nil? || @usernames.empty?
      puts "USERNAMES environment variable not set. Skipping aggregation."
      return
    end

    puts "Aggregating statistics for usernames: #{@usernames.join(', ')}"

    json_files = Dir.glob(File.join(@statistics_dir, '*.json'))

    if json_files.empty?
      puts "No statistics files found in #{@statistics_dir}"
      return
    end

    json_files.each do |file|
      process_repository_stats(file)
    end

    save_aggregated_stats
    generate_markdown_report
  end

  private

  def parse_usernames(usernames_env)
    return [] if usernames_env.nil? || usernames_env.empty?
    usernames_env.split(',').map(&:strip).reject(&:empty?)
  end

  def process_repository_stats(file)
    begin
      data = JSON.parse(File.read(file))

      # Check if this user has any commits in this repository
      user_commits = find_user_commits(data['commit_statistics'])

      if user_commits.any?
        puts "  Processing #{data['repository']} - found #{user_commits.length} matching authors"

        @aggregated_stats[:total_repositories] += 1
        user_commit_stats = aggregate_user_commits(user_commits)

        @aggregated_stats[:repositories] << {
          name: data['repository'],
          owner: data['owner'],
          description: data['description'],
          language: data['language'],
          user_commits: user_commit_stats,
          languages: data['language_statistics'] || {}
        }

        # Aggregate language statistics from repository-level data
        if data['language_statistics']
          data['language_statistics'].each do |lang, stats|
            @aggregated_stats[:languages][lang][:bytes] += stats['bytes'] || 0
          end
        end

        # Aggregate language statistics from user commits
        aggregate_user_language_contributions(user_commits)
      end

    rescue JSON::ParserError => e
      puts "  Error parsing #{file}: #{e.message}"
    rescue => e
      puts "  Error processing #{file}: #{e.message}"
    end
  end

  def find_user_commits(commit_statistics)
    return [] unless commit_statistics

    # Find commits that match any of the usernames (case-insensitive)
    # Also try to match by email domain or partial name matching
    matching_commits = commit_statistics.select do |author, stats|
      author_lower = author.downcase
      email = stats['email'] || ''
      email_username = email.split('@').first&.downcase

      # Check if author matches any of the configured usernames
      @usernames.any? do |username|
        username_lower = username.downcase

        # Direct name match
        author_lower.include?(username_lower) ||
        # Email username match (before @)
        email_username == username_lower ||
        # Exact match
        author_lower == username_lower
      end
    end

    matching_commits
  end

  def aggregate_user_commits(user_commits)
    total_commits = 0
    total_additions = 0
    total_deletions = 0

    user_commits.each do |author, stats|
      total_commits += stats['commits'] || 0
      total_additions += stats['additions'] || 0
      total_deletions += stats['deletions'] || 0
    end

    @aggregated_stats[:total_commits] += total_commits
    @aggregated_stats[:total_additions] += total_additions
    @aggregated_stats[:total_deletions] += total_deletions

    {
      commits: total_commits,
      additions: total_additions,
      deletions: total_deletions,
      authors: user_commits.keys
    }
  end

  def aggregate_user_language_contributions(user_commits)
    user_commits.each do |author, stats|
      if stats['languages']
        stats['languages'].each do |language, lang_stats|
          @aggregated_stats[:languages][language][:commits] += lang_stats['commits'] || 0
          @aggregated_stats[:languages][language][:additions] += lang_stats['additions'] || 0
          @aggregated_stats[:languages][language][:deletions] += lang_stats['deletions'] || 0
        end
      end
    end
  end

  def save_aggregated_stats
    filename = "#{@primary_username}_aggregated_stats.json"
    filepath = File.join(@statistics_dir, filename)

    # Calculate language percentages and totals
    # Use inject instead of sum for Ruby compatibility with nil safety
    language_values = @aggregated_stats[:languages].values || []
    total_language_bytes = language_values.map { |stats| (stats[:bytes] || 0) }.inject(0) { |sum, val| sum + val }
    total_language_additions = language_values.map { |stats| (stats[:additions] || 0) }.inject(0) { |sum, val| sum + val }

    language_percentages = {}

    @aggregated_stats[:languages].each do |lang, stats|
      bytes_percentage = total_language_bytes > 0 ? (stats[:bytes].to_f / total_language_bytes * 100).round(2) : 0
      additions_percentage = total_language_additions > 0 ? (stats[:additions].to_f / total_language_additions * 100).round(2) : 0

      language_percentages[lang] = {
        bytes: stats[:bytes],
        bytes_percentage: bytes_percentage,
        commits: stats[:commits],
        additions: stats[:additions],
        deletions: stats[:deletions],
        additions_percentage: additions_percentage,
        net_lines: stats[:additions] - stats[:deletions]
      }
    end

    # Convert Hash.new default to regular hash for JSON serialization
    @aggregated_stats[:languages] = language_percentages

    File.write(filepath, JSON.pretty_generate(@aggregated_stats))
    puts "Aggregated statistics saved to #{filepath}"
  end

  def generate_markdown_report
    filename = "#{@primary_username}_report.md"
    filepath = File.join(@statistics_dir, filename)

    markdown_content = generate_markdown_content
    File.write(filepath, markdown_content)
    puts "Markdown report generated: #{filepath}"
  end

  def generate_markdown_content
    stats = @aggregated_stats

    content = <<~MARKDOWN
      # Development Statistics Report for #{stats[:usernames].join(', ')}

      Generated on: #{stats[:generated_at]}

      ## Analyzed Usernames

      #{stats[:usernames].map { |u| "- #{u}" }.join("\n")}

      ## Summary

      - **Total Repositories**: #{stats[:total_repositories]}
      - **Total Commits**: #{stats[:total_commits]}
      - **Total Lines Added**: #{stats[:total_additions]}
      - **Total Lines Deleted**: #{stats[:total_deletions]}
      - **Net Lines**: #{stats[:total_additions] - stats[:total_deletions]}

      ## Language Distribution

    MARKDOWN

    if stats[:languages].any?
      content += "### By Code Lines Added\n\n"
      content += "| Language | Lines Added | Lines Deleted | Net Lines | Commits | % of Total Lines |\n"
      content += "|----------|-------------|---------------|-----------|---------|------------------|\n"

      sorted_by_additions = stats[:languages].sort_by { |_, data| -data[:additions] }
      sorted_by_additions.each do |language, data|
        content += "| #{language} | #{format_number(data[:additions])} | #{format_number(data[:deletions])} | #{format_number(data[:net_lines])} | #{data[:commits]} | #{data[:additions_percentage]}% |\n"
      end

      content += "\n### By Repository Bytes\n\n"
      content += "| Language | Repository Bytes | % of Repository |\n"
      content += "|----------|------------------|------------------|\n"

      sorted_by_bytes = stats[:languages].sort_by { |_, data| -data[:bytes] }
      sorted_by_bytes.each do |language, data|
        if data[:bytes] > 0
          content += "| #{language} | #{format_bytes(data[:bytes])} | #{data[:bytes_percentage]}% |\n"
        end
      end
    else
      content += "No language statistics available.\n"
    end

    content += "\n## Repository Details\n\n"

    if stats[:repositories].any?
      stats[:repositories].each do |repo|
        content += "### #{repo[:name]}\n\n"
        content += "- **Owner**: #{repo[:owner]}\n"
        content += "- **Description**: #{repo[:description] || 'No description'}\n"
        content += "- **Primary Language**: #{repo[:language] || 'Not specified'}\n"
        content += "- **Your Commits**: #{repo[:user_commits][:commits]}\n"
        content += "- **Lines Added**: #{repo[:user_commits][:additions]}\n"
        content += "- **Lines Deleted**: #{repo[:user_commits][:deletions]}\n\n"
      end
    else
      content += "No repositories found with commits from #{stats[:usernames].join(', ')}.\n"
    end

    content
  end

  def format_bytes(bytes)
    units = ['B', 'KB', 'MB', 'GB']
    size = bytes.to_f
    unit_index = 0

    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end

    "#{size.round(2)} #{units[unit_index]}"
  end

  def format_number(number)
    number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end

# Run the aggregator
if __FILE__ == $0
  aggregator = StatisticsAggregator.new
  aggregator.aggregate
end
