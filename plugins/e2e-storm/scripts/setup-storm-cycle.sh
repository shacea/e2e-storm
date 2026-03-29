#!/bin/bash

# E2E Storm Cycle Loop Setup
# storm 커맨드용 — git worktree 생성 + 자율 테스트-수정 루프 초기화

set -euo pipefail

# 기본값
MAX_CYCLES=10
AGENTS=10
SCENARIOS_DIR=""
URL=""
PROJECT_PATH=""
APP_CODE_FIX="true"
PROMPT_PARTS=()

show_help() {
  cat << 'HELP_EOF'
E2E Storm Cycle — 자율 테스트-수정 반복 루프

USAGE:
  /e2e-storm:storm [OPTIONS]

OPTIONS:
  --url <URL>              테스트 대상 URL
  --dir <PATH>             시나리오 디렉토리
  --project <PATH>         대상 프로젝트 경로 (앱 코드 수정 시)
  --agents <N>             병렬 에이전트 수 (기본: 10)
  --max-cycles <N>         최대 반복 cycle 수 (기본: 10)
  --no-app-fix             앱 코드 수정 비허용
  -h, --help               도움말

DESCRIPTION:
  E2E 테스트 실행 → 에러 취합 → 자동 분류/수정 → 메트릭 기반 keep/discard
  → PR 생성까지의 전체 사이클을 자동으로 반복한다.

  모든 작업은 git worktree에서 격리 수행되어 main 브랜치에 영향 없음.

EXAMPLES:
  /e2e-storm:storm
  /e2e-storm:storm --url https://example.com --dir e2e-storm/ --max-cycles 5
HELP_EOF
  exit 0
}

# 인자 파싱
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) show_help ;;
    --url)
      [[ -z "${2:-}" ]] && { echo "❌ --url 은 URL 필요" >&2; exit 1; }
      URL="$2"; shift 2 ;;
    --dir)
      [[ -z "${2:-}" ]] && { echo "❌ --dir 는 경로 필요" >&2; exit 1; }
      SCENARIOS_DIR="$2"; shift 2 ;;
    --project)
      [[ -z "${2:-}" ]] && { echo "❌ --project 는 경로 필요" >&2; exit 1; }
      PROJECT_PATH="$2"; shift 2 ;;
    --agents)
      [[ -z "${2:-}" ]] || [[ ! "$2" =~ ^[0-9]+$ ]] && { echo "❌ --agents 는 양의 정수 필요" >&2; exit 1; }
      AGENTS="$2"; shift 2 ;;
    --max-cycles)
      [[ -z "${2:-}" ]] || [[ ! "$2" =~ ^[0-9]+$ ]] && { echo "❌ --max-cycles 는 양의 정수 필요" >&2; exit 1; }
      MAX_CYCLES="$2"; shift 2 ;;
    --no-app-fix)
      APP_CODE_FIX="false"; shift ;;
    *)
      PROMPT_PARTS+=("$1"); shift ;;
  esac
done

# 세션 ID
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
BRANCH_SLUG="e2e-storm/$(date +%Y-%m-%d)-cycle"

# .claude 디렉토리 확인
mkdir -p .claude

# 인터랙티브 모드 플래그
INTERACTIVE="false"
if [[ -z "$URL" ]] && [[ -z "$SCENARIOS_DIR" ]]; then
  INTERACTIVE="true"
fi

# 루프 프롬프트 생성
LOOP_PROMPT="E2E Storm 자율 테스트-수정 루프.

## 모드
INTERACTIVE=$INTERACTIVE

## 설정
- URL: ${URL:-미설정}
- SCENARIOS_DIR: ${SCENARIOS_DIR:-미설정}
- PROJECT_PATH: ${PROJECT_PATH:-미설정}
- AGENTS: $AGENTS
- MAX_CYCLES: $MAX_CYCLES
- APP_CODE_FIX: $APP_CODE_FIX
- BRANCH: $BRANCH_SLUG

## 인터랙티브 모드 (INTERACTIVE=true일 때)

옵션이 부족하면 아래 정보를 사용자에게 순차적으로 질문한다:
1. 테스트할 프로젝트 URL (또는 로컬 경로 자동 감지)
2. 시나리오 디렉토리 경로 (없으면 /e2e-storm:generate 실행 제안)
3. 병렬 에이전트 수 (기본: 10)
4. 최대 cycle 수 (기본: 10)
5. 앱 코드 수정 허용 여부 (Y/n)
설정 확인 후 Phase 0부터 시작한다.

## Phase 0: Preflight

1. 대상 프로젝트에서 git worktree를 생성한다:
   - 브랜치명: $BRANCH_SLUG
   - \`git worktree add /tmp/e2e-storm-wt-{session} -b {branch}\` (대상 프로젝트 디렉토리에서 실행)
   - worktree에서 .env 복사, npm install 등 의존성 설치
2. state.json을 초기화한다:
   \`\`\`json
   {
     \"branch\": \"$BRANCH_SLUG\",
     \"worktree_path\": \"/tmp/e2e-storm-wt-...\",
     \"cycle\": 0,
     \"max_cycles\": $MAX_CYCLES,
     \"app_code_fix_allowed\": $APP_CODE_FIX,
     \"target_project_path\": \"...\",
     \"phases\": { \"current\": \"preflight\", \"last_heartbeat\": \"...\" },
     \"metrics\": {
       \"history\": [],
       \"consecutive_no_improve\": 0,
       \"no_improve_threshold\": 3
     },
     \"conflict_map\": \"conflict-map.json\",
     \"prs_created\": [],
     \"results_tsv\": \"results.tsv\",
     \"recovery\": { \"attempts\": 0, \"max_attempts\": 3 }
   }
   \`\`\`
3. results.tsv 헤더를 생성한다:
   \`cycle\tpass_rate\ttotal\tpass\tfail\tskip\tdecision\tcommit\`

## Phase 1: Conflict Analysis

conflict-analyzer 에이전트를 Agent 도구로 spawn한다:
- subagent_type은 사용하지 않고 일반 Agent로 spawn
- 프롬프트에 project_path, scenarios_dir, num_agents, config 정보 전달
- 에이전트의 conflict-analyzer.md 내용을 프롬프트에 포함 (Read 도구로 \${PLUGIN_ROOT}/agents/conflict-analyzer.md 읽기)
- 결과: conflict-map.json 생성

conflict-map을 읽고 기존 시나리오 파일에 isolation 블록을 주입한다.

heartbeat 갱신: phase=conflict_analysis, cycle=현재

## Phase 2: Test Execution

기존 /e2e-storm:execute 로직과 동일하되:
- conflict-map의 isolation 규칙을 각 에이전트 프롬프트에 포함
- 에이전트별 독립 브라우저 컨텍스트 명시
- 에이전트별 할당된 계정/data_prefix 사용 지시

N개 에이전트를 Agent 도구로 **동시에** spawn한다.
모든 에이전트 완료 후 결과를 수집한다.

heartbeat 갱신: phase=execution, cycle=현재

## Phase 3: Error Triage

error-triager 에이전트를 Agent 도구로 spawn한다:
- 프롬프트에 cycle, scenarios_dir, project_path, round_results_dir, errors_dir 전달
- 에이전트의 error-triager.md 내용을 프롬프트에 포함
- 결과: triage-{cycle}.json 생성

triage 요약을 확인한다.
FAIL이 0이면 Phase 5로 직행 (수정 불필요).

heartbeat 갱신: phase=triage, cycle=현재

## Phase 4: Auto-Fix + Commit

auto-fixer 에이전트를 Agent 도구로 spawn한다:
- 프롬프트에 cycle, scenarios_dir, project_path(worktree), triage_file, app_code_fix_allowed, conflict_map_file 전달
- 에이전트의 auto-fixer.md 내용을 프롬프트에 포함
- 결과: 시나리오/앱 코드 수정 완료

수정 완료 후:
1. worktree 디렉토리에서 변경 파일을 git add
2. 커밋: \`fix(e2e-storm): cycle-{N} — {TYPE-A N건, TYPE-B N건 수정}\`
3. 커밋 해시를 기록

heartbeat 갱신: phase=fix, cycle=현재

## Phase 5: Metric Judgment

pass_rate를 계산한다:
\`pass_rate = pass / (total - skip) * 100\`

이전 cycle과 비교한다:
- **개선됨 (current > prev)**: KEEP
  - consecutive_no_improve = 0
  - results.tsv에 keep 기록
- **악화 또는 동일 (current <= prev)**: DISCARD
  - worktree에서 \`git reset --hard HEAD~{이번 cycle 커밋 수}\`
  - consecutive_no_improve += 1
  - results.tsv에 discard 기록

consecutive_no_improve >= no_improve_threshold (3) 이면:
- Phase 6으로 이동하여 PR 생성 후 루프 일시 중단

state.json의 metrics.history에 이번 cycle 결과를 추가한다.

heartbeat 갱신: phase=judgment, cycle=현재

## Phase 6: PR & Continuation

현재까지 KEEP된 커밋이 있으면:
1. worktree에서 \`git push -u origin {branch}\`
2. \`gh pr create --title \"e2e-storm: cycle {N} fixes\" --body \"...\"\`
3. PR URL을 state.json의 prs_created에 추가
4. 사용자에게 알림: \"Cycle {N} 완료. Pass rate: X% → Y%. PR #{num} 생성됨.\"

루프 계속 여부:
- cycle < max_cycles AND consecutive_no_improve < threshold → Phase 2로 복귀
- 그렇지 않으면 → 최종 요약 출력 + \`<promise>STORM_CYCLE_COMPLETE</promise>\`

heartbeat 갱신: phase=pr, cycle=현재

## 완료 조건

아래 중 하나가 충족되면 루프 종료:
1. cycle >= max_cycles
2. consecutive_no_improve >= no_improve_threshold
3. pass_rate == 100%
4. 사용자가 /e2e-storm:cancel 실행

종료 시 \`<promise>STORM_CYCLE_COMPLETE</promise>\` 출력.

## 매 Phase 시작 시 반드시 실행

1. heartbeat 갱신: \`bash \"\${PLUGIN_ROOT}/scripts/heartbeat.sh\" update {phase} {cycle}\`
   (또는 .claude/e2e-storm-heartbeat.json에 직접 Write)
2. state.json의 phases.current 업데이트"

# 상태 파일 생성
cat > .claude/e2e-storm-storm-loop.local.md <<EOF
---
iteration: 1
max_iterations: $MAX_CYCLES
completion_promise: "STORM_CYCLE_COMPLETE"
session_id: $SESSION_ID
loop_type: storm
---
$LOOP_PROMPT
EOF

# 결과 디렉토리 생성
if [[ -n "$SCENARIOS_DIR" ]]; then
  mkdir -p "$SCENARIOS_DIR/results" "$SCENARIOS_DIR/errors"
fi

# 시작 메시지
echo ""
echo "⚡ E2E Storm 자율 테스트-수정 루프 시작!"
echo ""
if [[ "$INTERACTIVE" == "true" ]]; then
  echo "   📋 인터랙티브 모드 — AI가 필요한 정보를 질문합니다"
else
  echo "   🌐 URL: $URL"
  echo "   📁 시나리오: $SCENARIOS_DIR"
  echo "   🤖 에이전트: $AGENTS"
  echo "   🔄 최대 cycle: $MAX_CYCLES"
  echo "   🔧 앱 코드 수정: $APP_CODE_FIX"
fi
echo ""
echo "   취소: /e2e-storm:cancel"
echo ""

# 초기 프롬프트 출력
echo "$LOOP_PROMPT"
