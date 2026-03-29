---
description: "E2E Storm 자율 테스트-수정 반복 루프. 테스트 → 에러 취합 → 자동 수정 → 메트릭 판정 → PR 생성을 반복. git worktree로 main 보호."
argument-hint: "[--url URL] [--dir PATH] [--project PATH] [--agents N] [--max-cycles N] [--no-app-fix]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-storm-cycle.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh:*)"]
---

# E2E Storm: Storm (자율 테스트-수정 루프)

자율적으로 E2E 테스트를 실행하고, 에러를 분석/수정하며, 메트릭 기반으로 keep/discard 판정 후 PR을 생성하는 전체 루프를 실행한다.

모든 작업은 **git worktree**에서 격리 수행되어 **main 브랜치에 절대 영향 없음**.

## 사전 요구사항

- Playwright MCP 서버 연결 필요
- `gh` CLI 설치 및 인증 필요 (PR 생성용)
- 대상 프로젝트가 git 저장소여야 함

## 루프 시작

아래 명령으로 루프를 초기화한다:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-storm-cycle.sh" $ARGUMENTS
```

## 핵심 규칙

### 절대 금지
- main 브랜치에서 직접 코드 수정
- worktree 바깥 파일 수정
- conflict-map의 isolation 규칙 위반
- 메트릭 악화 시 커밋 유지 (반드시 DISCARD)

### 반드시 준수
- 모든 코드 수정은 worktree 내에서만
- 매 Phase 시작 시 heartbeat 갱신
- 매 cycle 결과를 state.json과 results.tsv에 기록
- KEEP 판정 시에만 커밋 유지, DISCARD 시 git reset

## 에이전트 활용

이 커맨드는 3개의 전문 에이전트를 활용한다:

| Phase | 에이전트 | 역할 |
|-------|---------|------|
| Phase 1 | conflict-analyzer | 코드 분석 → conflict-map 생성 |
| Phase 3 | error-triager | 에러 분류 (TYPE-A/B/C) |
| Phase 4 | auto-fixer | 시나리오/앱 코드 자동 수정 |

에이전트 프롬프트에는 반드시 해당 에이전트의 전체 지시사항을 포함해야 한다.
에이전트 지시사항은 `${CLAUDE_PLUGIN_ROOT}/agents/` 디렉토리의 해당 .md 파일을 Read 도구로 읽어서 전달한다.

## 테스트 에이전트 격리 규칙

Phase 2에서 테스트 에이전트를 spawn할 때:

1. conflict-map.json의 `agent_assignments`에서 해당 에이전트의 규칙을 읽는다
2. 에이전트 프롬프트에 아래 내용을 포함한다:
   - `isolation.data_prefix`: 데이터 생성 시 이 접두사 사용
   - `isolation.account`: 이 계정으로 로그인
   - `isolation.allowed_mutations`: 허용된 데이터 변이만 수행
   - `isolation.browser_context`: 독립 브라우저 컨텍스트에서 실행
3. 각 에이전트의 시나리오 JSON에도 isolation 블록이 포함되어 있어야 한다

## Watchdog

세션 종료 시 stop-hook이 heartbeat를 확인한다:
- heartbeat가 3분 이상 경과 → 루프 멈춤으로 판단 → 해당 Phase부터 재시작
- 같은 Phase에서 3회 연속 복구 실패 → 루프 완전 중단 + 사용자 알림
