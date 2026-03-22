#!/bin/bash

# E2E Storm Loop Setup
# ralph-loop 메커니즘으로 테스트 루프를 초기화한다.

set -euo pipefail

# 기본값
MAX_ITERATIONS=0
COMPLETION_PROMISE="ALL_SCENARIOS_VERIFIED"
AGENTS=10
SCENARIOS_DIR="e2e-storm"
PROMPT_PARTS=()

# 도움말
show_help() {
  cat << 'HELP_EOF'
E2E Storm Execute — Playwright 병렬 E2E 테스트 실행 루프

USAGE:
  /e2e-storm:execute [OPTIONS]

OPTIONS:
  --agents <N>             병렬 에이전트 수 (기본: 10)
  --dir <PATH>             시나리오 디렉토리 (기본: e2e-storm/)
  --max-iterations <N>     최대 반복 수 (기본: 무제한)
  -h, --help               도움말

DESCRIPTION:
  생성된 E2E 시나리오를 Playwright 브라우저로 병렬 실행한다.
  모든 시나리오가 2회 연속 완전히 테스트될 때까지 반복한다.

  완료 조건: <promise>ALL_SCENARIOS_VERIFIED</promise>

EXAMPLES:
  /e2e-storm:execute --agents 10
  /e2e-storm:execute --dir my-tests/ --agents 5 --max-iterations 20
HELP_EOF
  exit 0
}

# 인자 파싱
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    --agents)
      if [[ -z "${2:-}" ]] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ --agents 는 양의 정수 필요 (예: --agents 10)" >&2
        exit 1
      fi
      AGENTS="$2"
      shift 2
      ;;
    --dir)
      if [[ -z "${2:-}" ]]; then
        echo "❌ --dir 는 경로 필요 (예: --dir e2e-storm/)" >&2
        exit 1
      fi
      SCENARIOS_DIR="$2"
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ --max-iterations 는 양의 정수 필요" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    *)
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

# 시나리오 디렉토리 확인
if [[ ! -d "$SCENARIOS_DIR" ]]; then
  echo "❌ 시나리오 디렉토리를 찾을 수 없음: $SCENARIOS_DIR" >&2
  echo "   먼저 /e2e-storm:generate 로 시나리오를 생성하세요." >&2
  exit 1
fi

if [[ ! -f "$SCENARIOS_DIR/index.json" ]]; then
  echo "❌ index.json을 찾을 수 없음: $SCENARIOS_DIR/index.json" >&2
  echo "   먼저 /e2e-storm:generate 로 시나리오를 생성하세요." >&2
  exit 1
fi

# 세션 ID (Claude Code 환경에서 제공되는 경우)
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"

# .claude 디렉토리 확인
mkdir -p .claude

# YAML에서 completion promise 안전하게 인용
COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""

# 루프 프롬프트 생성
LOOP_PROMPT="E2E Storm 테스트 실행 라운드.

## 지시사항

1. \`$SCENARIOS_DIR/state.json\` 을 읽어 현재 진행 상황을 확인한다. 파일이 없으면 초기 상태로 생성한다.
2. \`$SCENARIOS_DIR/index.json\` 과 \`$SCENARIOS_DIR/scenarios/\` 에서 시나리오를 로드한다.
3. 이전 라운드 결과를 분석하여 미완료/실패 시나리오를 파악한다.
4. $AGENTS 개의 에이전트를 Agent 도구로 병렬 spawn한다. 각 에이전트에게:
   - 담당 시나리오 JSON을 전달
   - Playwright MCP 도구(browser_navigate, browser_click, browser_fill_form, browser_snapshot, browser_press_key, browser_wait_for, browser_take_screenshot 등)로 실제 브라우저 테스트 수행 지시
   - curl, fetch, requests 등 HTTP 직접 호출 절대 금지
   - 실제 사람처럼 마우스 클릭, 키보드 입력으로 테스트
   - 결과를 \`$SCENARIOS_DIR/results/round-{N}/agent-{NN}-results.json\` 에 저장
5. 모든 에이전트 완료 후:
   - 결과를 수집하여 \`$SCENARIOS_DIR/state.json\` 업데이트
   - FAIL 시나리오를 \`$SCENARIOS_DIR/errors/\` 에 개별 저장
   - 모든 시나리오 테스트 완료 여부 확인
6. 완료 판정:
   - 모든 시나리오가 빠짐없이 테스트되었고 이것이 2회 연속이면: \`<promise>ALL_SCENARIOS_VERIFIED</promise>\` 출력
   - 그렇지 않으면: 진행 상황을 요약하고 종료 (ralph-loop이 자동으로 다음 라운드 시작)

## 에이전트 프롬프트 템플릿

각 에이전트에 아래 구조의 프롬프트를 전달한다:
\`\`\`
너는 E2E 테스트 에이전트다. 반드시 Playwright MCP 도구로 실제 브라우저를 조작하여 테스트한다.

필수 규칙:
- browser_navigate, browser_click, browser_fill_form, browser_snapshot, browser_press_key, browser_type, browser_wait_for 도구만 사용
- curl/fetch/requests 등 HTTP 직접 호출 금지
- 각 시나리오 시작 전 browser_snapshot으로 현재 상태 확인
- 실패 시 browser_take_screenshot으로 스크린샷 저장
- 결과는 지정된 경로에 JSON으로 저장

테스트 계정: (index.json의 test_account 정보)
담당 시나리오: (배정된 시나리오 JSON)

결과 JSON 스키마:
{
  \"agent_id\": N,
  \"round\": N,
  \"tested_at\": \"ISO timestamp\",
  \"summary\": { \"total\": N, \"pass\": N, \"fail\": N, \"skip\": N },
  \"results\": [
    {
      \"id\": \"S001\",
      \"title\": \"제목\",
      \"status\": \"PASS|FAIL|SKIP\",
      \"method\": \"playwright\",
      \"details\": \"상세 내용\",
      \"error\": null | \"에러 메시지\",
      \"screenshot\": null | \"스크린샷 경로\",
      \"suggested_fix\": null | \"수정 제안\"
    }
  ]
}
\`\`\`

## state.json 스키마
\`\`\`json
{
  \"total_scenarios\": N,
  \"agents\": $AGENTS,
  \"current_round\": N,
  \"consecutive_complete_rounds\": 0,
  \"status\": \"running\",
  \"rounds\": [
    {
      \"round\": N,
      \"started_at\": \"ISO\",
      \"completed_at\": \"ISO\",
      \"total\": N,
      \"tested\": N,
      \"pass\": N,
      \"fail\": N,
      \"skip\": N,
      \"untested\": N,
      \"complete\": false
    }
  ]
}
\`\`\`"

# 상태 파일 생성 (YAML frontmatter + 프롬프트)
cat > .claude/e2e-storm-loop.local.md <<EOF
---
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
session_id: $SESSION_ID
---
$LOOP_PROMPT
EOF

# 결과 디렉토리 생성
mkdir -p "$SCENARIOS_DIR/results" "$SCENARIOS_DIR/errors"

# 시작 메시지
echo ""
echo "⚡ E2E Storm 테스트 루프 시작!"
echo ""
echo "   📁 시나리오 디렉토리: $SCENARIOS_DIR"
echo "   🤖 병렬 에이전트: $AGENTS"
if [[ $MAX_ITERATIONS -gt 0 ]]; then
  echo "   🔄 최대 반복: $MAX_ITERATIONS"
else
  echo "   🔄 최대 반복: 무제한"
fi
echo "   ✅ 완료 조건: 모든 시나리오 2회 연속 완전 검증"
echo ""
echo "   취소: /e2e-storm:cancel"
echo ""

# 초기 프롬프트 출력
echo "$LOOP_PROMPT"
