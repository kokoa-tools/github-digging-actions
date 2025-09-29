# Github Digging Actions

## 요구사항

- 한달에 한번씩 Repository를 분석하는 github actions를 만듭니다.
- 분석할 레포지터리를 선택하는 방법은 아래와 같습니다.
  - 특정 유저 / 조직에 대해서 다수 선택할 수 있습니다. 이는 Gihub actions 환경변수를 통해 제공합니다. ","를 기준으로 split하여 가져옵니다
  - 만약 "/" 문자가 있다면 특정 유저의 특정 레포지터리만 선택한 것입니다. 만약 없다면 그 유저/조직의 모든 레포를 뜻합니다.
- 이 actions을 통해서 유저 / 조직에 있는 모든 public, private Repository들을 가져옵니다. 그리고 해당 action의 서브 동작으로 각 github repo의 commit 마다 어떤 유저가 얼만큼 어떤 프로그래밍 언어로 몇 라인, 몇개의 커밋이 되었는지를 통계를 조사하여 만듭니다. (이 과정은 ruby 스크립트를 통해 진행합니다.)
- 각 repository 별로 통계들을 statistics/ 내에 json 파일로 기록합니다.
- 그리고 전체 액션에서 서브 동작으로 가져온 통계들을 통합합니다. 이때는 USERNAME을 지정하면 해당 Username의 통계를 모두 추합하여 하나의 json 파일과 markdown 파일을 만듭니다.

## 설정 방법

### 로컬 개발 및 테스트

1. **의존성 설치**:
   ```bash
   bundle install
   ```

2. **환경 변수 설정**:
   ```bash
   cp .env.example .env
   # .env 파일을 열어서 실제 값으로 수정
   ```

3. **로컬 실행**:
   ```bash
   # 저장소 분석 실행
   bundle exec ruby scripts/analyze_repositories.rb

   # 통계 집계 실행 (분석 완료 후)
   bundle exec ruby scripts/aggregate_statistics.rb
   ```

### 1. GitHub Actions Variables 설정

Repository Settings > Secrets and variables > Actions > Variables에서 다음 변수들을 설정하세요:

- `REPOSITORIES`: 분석할 저장소 목록 (쉼표로 구분)
  - 예시: `octocat,github/docs,microsoft`
  - `octocat`: octocat 사용자의 모든 저장소
  - `github/docs`: github 조직의 docs 저장소만
  - `microsoft`: microsoft 조직의 모든 저장소

- `USERNAMES`: 통계를 집계할 사용자명들 (선택사항, 쉼표로 구분)
  - 예시: `john-doe,johndoe,j.doe`
  - 여러 사용자명을 하나의 사람으로 간주하여 통계를 통합

- `MAX_THREADS`: 병렬 처리 스레드 수 (선택사항)
  - 기본값: 4
  - 분석 속도 향상을 위해 조정 가능 (권장: 2-8)
  - GitHub API 속도 제한에 주의

- `CACHE_HOURS`: 캐시 지속 시간(시간) (선택사항)
  - 기본값: 3시간
  - 최근에 분석한 저장소는 이 시간 동안 재분석하지 않음
  - API 속도 제한 방지에 도움
  - 0으로 설정하면 캐시 비활성화

- `INCLUDE_PRIVATE_REPOS`: Private 저장소 포함 여부 (선택사항)
  - 기본값: false (Public 저장소만)
  - true로 설정하면 Private 저장소도 분석에 포함
  - GitHub 토큰에 Private 저장소 접근 권한 필요

### 2. GitHub Token 권한

GitHub Actions는 기본 `GH_TOKEN`을 사용합니다. Private 저장소에 접근하려면 Personal Access Token이 필요할 수 있습니다.

### 3. 수동 실행

Actions 탭에서 "Monthly Repository Analysis" 워크플로우를 수동으로 실행할 수 있습니다.

### 4. 결과 확인

- **analysis 브랜치**: 분석 결과가 저장되는 별도 브랜치
- **지능형 이어하기**: 이전 실행의 캐시된 결과와 오류 로그를 활용
  - 기존 `statistics/` 폴더가 있으면 자동으로 가져와서 캐시로 활용
  - `error_report.json`이 있으면 실패한 저장소를 자동으로 재시도
  - 오류 개수에 따라 커밋 메시지에 상태 표시
- `statistics/` 폴더에만 분석 결과 파일들이 포함됨

## 파일 구조

```
.github/workflows/repository-analysis.yml  # GitHub Actions 워크플로우
scripts/analyze_repositories.rb            # 저장소 분석 스크립트
scripts/aggregate_statistics.rb            # 통계 집계 스크립트
statistics/                                # 통계 결과 저장 폴더
├── owner_repo.json                        # 각 저장소별 통계
├── username_aggregated_stats.json         # 사용자별 집계 통계
└── username_report.md                     # 마크다운 리포트
```

## 생성되는 파일

### 저장소별 통계 (`statistics/{owner}_{repo}.json`)
- 저장소 기본 정보
- 커밋 통계 (작성자별 커밋 수, 추가/삭제 라인 수)
- 프로그래밍 언어 분포

### 사용자별 집계 (`statistics/{username}_aggregated_stats.json`)
- 전체 저장소에서의 활동 통계
- 언어별 기여도
- 저장소별 상세 기여 내역

### 마크다운 리포트 (`statistics/{username}_report.md`)
- 가독성 좋은 형태의 통계 리포트
- 표와 차트 형태의 데이터 시각화

### 오류 보고서 (오류 발생 시만 생성)
- `statistics/error_report.json`: 상세한 오류 정보 (JSON 형식)
- `statistics/error_summary.md`: 가독성 좋은 오류 요약 (마크다운 형식)
- 권한 오류, API 제한, 네트워크 오류 등을 카테고리별로 분류
- **자동 재시도**: 다음 실행 시 오류가 발생한 저장소들을 자동으로 재분석
- 성공적으로 분석되면 오류 목록에서 자동 제거
