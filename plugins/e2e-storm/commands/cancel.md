---
description: "활성 E2E Storm 루프 취소 (execute 및 storm 루프 모두)"
---

# E2E Storm: Cancel

활성 E2E Storm 테스트 루프를 취소한다.

execute 루프 (`.claude/e2e-storm-loop.local.md`) 및 storm 루프 (`.claude/e2e-storm-storm-loop.local.md`)를 모두 확인하여 삭제한다. heartbeat 파일도 정리한다.

```!
CANCELLED=false

if [ -f .claude/e2e-storm-storm-loop.local.md ]; then
  rm .claude/e2e-storm-storm-loop.local.md
  echo "🛑 E2E Storm 자율 루프가 취소되었습니다."
  CANCELLED=true
fi

if [ -f .claude/e2e-storm-loop.local.md ]; then
  rm .claude/e2e-storm-loop.local.md
  echo "🛑 E2E Storm 실행 루프가 취소되었습니다."
  CANCELLED=true
fi

if [ -f .claude/e2e-storm-heartbeat.json ]; then
  rm .claude/e2e-storm-heartbeat.json
  echo "   Heartbeat 파일 정리됨."
fi

if [ "$CANCELLED" = true ]; then
  echo "   결과는 e2e-storm/ 디렉토리에서 확인할 수 있습니다."
else
  echo "ℹ️  활성 E2E Storm 루프가 없습니다."
fi
```
