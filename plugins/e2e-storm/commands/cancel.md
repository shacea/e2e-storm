---
description: "활성 E2E Storm 루프 취소"
---

# E2E Storm: Cancel

활성 E2E Storm 테스트 루프를 취소한다.

상태 파일 `.claude/e2e-storm-loop.local.md`이 존재하면 삭제하여 루프를 중지한다.

```!
if [ -f .claude/e2e-storm-loop.local.md ]; then
  rm .claude/e2e-storm-loop.local.md
  echo "🛑 E2E Storm 루프가 취소되었습니다."
  echo "   결과는 e2e-storm/results/ 에서 확인할 수 있습니다."
else
  echo "ℹ️  활성 E2E Storm 루프가 없습니다."
fi
```
