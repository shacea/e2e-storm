#!/bin/bash

# E2E Storm Stop Hook
# ralph-loop 메커니즘 — 테스트 루프(execute/storm)가 활성화되어 있으면 종료를 차단하고 프롬프트를 다시 주입한다.
# storm 루프인 경우 watchdog heartbeat도 확인한다.

set -euo pipefail

HOOK_INPUT=$(cat)

# --- STATE_FILE 결정: storm 루프 우선 ---
STATE_FILE=""
LOOP_TYPE="execute"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEARTBEAT_SCRIPT="$SCRIPT_DIR/../scripts/heartbeat.sh"

if [[ -f ".claude/e2e-storm-storm-loop.local.md" ]]; then
  STATE_FILE=".claude/e2e-storm-storm-loop.local.md"
  LOOP_TYPE="storm"
elif [[ -f ".claude/e2e-storm-loop.local.md" ]]; then
  STATE_FILE=".claude/e2e-storm-loop.local.md"
  LOOP_TYPE="execute"
fi

if [[ -z "$STATE_FILE" ]]; then
  exit 0
fi

# YAML frontmatter 파싱
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

# 세션 격리: 다른 세션의 루프를 방해하지 않는다
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# 숫자 필드 검증
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  E2E Storm: iteration 필드 손상 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  E2E Storm: max_iterations 필드 손상 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

# 최대 반복 도달 확인
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 E2E Storm: 최대 반복 횟수($MAX_ITERATIONS) 도달. 루프 종료."
  rm "$STATE_FILE"
  [[ "$LOOP_TYPE" == "storm" ]] && [[ -f "$HEARTBEAT_SCRIPT" ]] && bash "$HEARTBEAT_SCRIPT" clean
  exit 0
fi

# 트랜스크립트 경로
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  E2E Storm: 트랜스크립트 파일 없음 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

# 마지막 어시스턴트 메시지에서 completion promise 확인
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  E2E Storm: 어시스턴트 메시지 없음 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
if [[ -z "$LAST_LINES" ]]; then
  rm "$STATE_FILE"
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]]; then
  echo "⚠️  E2E Storm: JSON 파싱 실패 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

# Completion promise 확인
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "✅ E2E Storm: 완료! <promise>$COMPLETION_PROMISE</promise>"
    rm "$STATE_FILE"
    [[ "$LOOP_TYPE" == "storm" ]] && [[ -f "$HEARTBEAT_SCRIPT" ]] && bash "$HEARTBEAT_SCRIPT" clean
    exit 0
  fi
fi

# 다음 반복 진행
NEXT_ITERATION=$((ITERATION + 1))

# 프롬프트 추출 (YAML frontmatter 이후의 모든 텍스트)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  E2E Storm: 프롬프트 텍스트 없음 — 루프 중지" >&2
  rm "$STATE_FILE"
  exit 0
fi

# --- Watchdog: Heartbeat 체크 (storm 루프 전용) ---
SYSTEM_MSG=""
if [[ "$LOOP_TYPE" == "storm" ]] && [[ -f "$HEARTBEAT_SCRIPT" ]]; then
  HEARTBEAT_RESULT=$(bash "$HEARTBEAT_SCRIPT" check)
  HEARTBEAT_STATUS=$(echo "$HEARTBEAT_RESULT" | head -1)

  if [[ "$HEARTBEAT_STATUS" == "stale" ]]; then
    STALE_INFO=$(echo "$HEARTBEAT_RESULT" | tail -1)
    STALE_PHASE=$(echo "$STALE_INFO" | jq -r '.phase // "unknown"' 2>/dev/null || echo "unknown")
    STALE_CYCLE=$(echo "$STALE_INFO" | jq -r '.cycle // 0' 2>/dev/null || echo "0")

    # recovery 시도 횟수 확인
    SCENARIOS_DIR=$(echo "$PROMPT_TEXT" | grep -oP 'SCENARIOS_DIR: \K[^ ]+' | head -1 || true)
    if [[ -n "$SCENARIOS_DIR" ]] && [[ -f "$SCENARIOS_DIR/state.json" ]]; then
      RECOVERY_ATTEMPTS=$(jq -r '.recovery.attempts // 0' "$SCENARIOS_DIR/state.json" 2>/dev/null || echo "0")
      MAX_RECOVERY=$(jq -r '.recovery.max_attempts // 3' "$SCENARIOS_DIR/state.json" 2>/dev/null || echo "3")

      if [[ $RECOVERY_ATTEMPTS -ge $MAX_RECOVERY ]]; then
        echo "🛑 E2E Storm: 복구 시도 ${RECOVERY_ATTEMPTS}회 초과. 루프 종료." >&2
        rm -f "$STATE_FILE"
        bash "$HEARTBEAT_SCRIPT" clean
        exit 0
      fi

      # recovery 횟수 증가
      TMP_STATE="$SCENARIOS_DIR/state.json.tmp.$$"
      jq ".recovery.attempts = $((RECOVERY_ATTEMPTS + 1))" "$SCENARIOS_DIR/state.json" > "$TMP_STATE" 2>/dev/null && \
        mv "$TMP_STATE" "$SCENARIOS_DIR/state.json" || rm -f "$TMP_STATE"
    fi

    SYSTEM_MSG="⚠️ E2E Storm 루프가 Phase $STALE_PHASE, Cycle $STALE_CYCLE에서 중단 감지됨. state.json을 읽고 해당 Phase부터 재개하라."
  fi
fi

# iteration 업데이트
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# 시스템 메시지 (watchdog에서 이미 설정되지 않은 경우)
if [[ -z "$SYSTEM_MSG" ]]; then
  if [[ "$LOOP_TYPE" == "storm" ]]; then
    SYSTEM_MSG="🔄 E2E Storm Cycle 라운드 $NEXT_ITERATION | 완료 조건: <promise>$COMPLETION_PROMISE</promise>"
  elif [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
    SYSTEM_MSG="🔄 E2E Storm 라운드 $NEXT_ITERATION | 완료 조건: <promise>$COMPLETION_PROMISE</promise> (모든 시나리오가 2회 연속 완전 검증되었을 때만 출력)"
  else
    SYSTEM_MSG="🔄 E2E Storm 라운드 $NEXT_ITERATION"
  fi
fi

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
