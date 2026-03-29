#!/bin/bash
# E2E Storm Heartbeat — Phase 전환 시 타임스탬프 기록 및 체크

set -euo pipefail

ACTION="${1:-check}"  # "update" or "check"
HEARTBEAT_FILE=".claude/e2e-storm-heartbeat.json"
TIMEOUT_SECONDS="${E2E_STORM_HEARTBEAT_TIMEOUT:-600}"  # 기본 10분

case "$ACTION" in
  update)
    PHASE="${2:?phase required}"
    CYCLE="${3:?cycle required}"
    mkdir -p .claude
    cat > "$HEARTBEAT_FILE" <<EOF
{
  "phase": "$PHASE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cycle": $CYCLE,
  "pid": $$
}
EOF
    ;;

  check)
    if [[ ! -f "$HEARTBEAT_FILE" ]]; then
      echo "no_heartbeat"
      exit 0
    fi

    LAST_TS=$(jq -r '.timestamp' "$HEARTBEAT_FILE" 2>/dev/null) || {
      echo "error"
      exit 0
    }
    if [[ -z "$LAST_TS" || "$LAST_TS" == "null" ]]; then
      echo "error"
      exit 0
    fi

    LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s 2>/dev/null || echo "")
    if [[ -z "$LAST_EPOCH" ]]; then
      echo "error"
      exit 0
    fi

    NOW_EPOCH=$(date +%s)
    DIFF=$((NOW_EPOCH - LAST_EPOCH))

    if [[ $DIFF -ge $TIMEOUT_SECONDS ]]; then
      echo "stale"
      jq -c '.' "$HEARTBEAT_FILE" 2>/dev/null || true
    else
      echo "alive"
    fi
    ;;

  clean)
    rm -f "$HEARTBEAT_FILE"
    ;;

  *)
    echo "Usage: heartbeat.sh {update|check|clean} [phase] [cycle]" >&2
    exit 1
    ;;
esac
