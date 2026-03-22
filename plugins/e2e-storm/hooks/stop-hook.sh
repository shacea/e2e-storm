#!/bin/bash

# E2E Storm Stop Hook
# ralph-loop 메커니즘 — 테스트 루프가 활성화되어 있으면 종료를 차단하고 프롬프트를 다시 주입한다.

set -euo pipefail

HOOK_INPUT=$(cat)

STATE_FILE=".claude/e2e-storm-loop.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
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
    echo "✅ E2E Storm: 모든 시나리오 검증 완료! <promise>$COMPLETION_PROMISE</promise>"
    rm "$STATE_FILE"
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

# iteration 업데이트
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# 시스템 메시지
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 E2E Storm 라운드 $NEXT_ITERATION | 완료 조건: <promise>$COMPLETION_PROMISE</promise> (모든 시나리오가 2회 연속 완전 검증되었을 때만 출력)"
else
  SYSTEM_MSG="🔄 E2E Storm 라운드 $NEXT_ITERATION"
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
