# E2E Storm Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** E2E Storm에 자율 테스트-수정 반복 루프(`/e2e-storm:storm`)를 추가하여, 테스트 실행 → 에러 취합 → 자동 분류/수정 → 메트릭 기반 keep/discard → PR 생성까지의 전체 사이클을 자동화한다.

**Architecture:** 새 `storm` 커맨드가 전체 루프를 오케스트레이션하고, 3개의 전문 에이전트(conflict-analyzer, error-triager, auto-fixer)가 각 Phase를 담당한다. 기존 ralph-loop의 stop-hook 패턴을 확장하여 heartbeat 기반 watchdog을 내장하고, git worktree로 main 브랜치를 보호한다.

**Tech Stack:** Claude Code Plugin (Markdown commands, agents), Bash scripts, Playwright MCP, git worktree, gh CLI

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `plugins/e2e-storm/commands/storm.md` | 통합 루프 오케스트레이션 커맨드 |
| `plugins/e2e-storm/agents/conflict-analyzer.md` | Phase 1: 코드 분석 → conflict-map 생성 |
| `plugins/e2e-storm/agents/error-triager.md` | Phase 3: 에러 분류 (TYPE-A/B/C) |
| `plugins/e2e-storm/agents/auto-fixer.md` | Phase 4: 시나리오/앱 코드 자동 수정 |
| `plugins/e2e-storm/scripts/setup-storm-loop.sh` | storm 루프 초기화 (worktree + state) |
| `plugins/e2e-storm/scripts/heartbeat.sh` | heartbeat 갱신/체크 유틸리티 |

### Modified Files
| File | Changes |
|------|---------|
| `plugins/e2e-storm/hooks/stop-hook.sh` | watchdog heartbeat 체크 + storm 루프 지원 추가 |
| `plugins/e2e-storm/hooks/hooks.json` | storm 루프용 Stop hook 설명 업데이트 |
| `plugins/e2e-storm/commands/execute.md` | isolation 블록 준수 로직 + 독립 브라우저 컨텍스트 명시 |
| `plugins/e2e-storm/commands/generate.md` | conflict-map 기반 isolation 블록 주입 Phase 추가 |
| `plugins/e2e-storm/commands/cancel.md` | storm 루프 파일도 정리하도록 확장 |
| `plugins/e2e-storm/.claude-plugin/plugin.json` | version 2.0.0 + agents 등록 |

---

### Task 1: heartbeat.sh 스크립트 생성

**Files:**
- Create: `plugins/e2e-storm/scripts/heartbeat.sh`

- [ ] **Step 1: heartbeat.sh 작성**

```bash
#!/bin/bash
# E2E Storm Heartbeat — Phase 전환 시 타임스탬프 기록 및 체크

set -euo pipefail

ACTION="${1:-check}"  # "update" or "check"
HEARTBEAT_FILE=".claude/e2e-storm-heartbeat.json"
TIMEOUT_SECONDS="${E2E_STORM_HEARTBEAT_TIMEOUT:-180}"  # 기본 3분

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

    LAST_TS=$(jq -r '.timestamp' "$HEARTBEAT_FILE")
    LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DIFF=$((NOW_EPOCH - LAST_EPOCH))

    if [[ $DIFF -ge $TIMEOUT_SECONDS ]]; then
      echo "stale"
      jq -c '.' "$HEARTBEAT_FILE"
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
```

- [ ] **Step 2: 실행 권한 부여 및 검증**

Run: `chmod +x plugins/e2e-storm/scripts/heartbeat.sh && bash plugins/e2e-storm/scripts/heartbeat.sh update test_phase 1 && bash plugins/e2e-storm/scripts/heartbeat.sh check && bash plugins/e2e-storm/scripts/heartbeat.sh clean`

Expected: `update` 성공, `check`에서 `alive` 출력, `clean` 후 파일 삭제

- [ ] **Step 3: 커밋**

```bash
git add plugins/e2e-storm/scripts/heartbeat.sh
git commit -m "feat(storm): add heartbeat utility script"
```

---

### Task 2: conflict-analyzer 에이전트 생성

**Files:**
- Create: `plugins/e2e-storm/agents/conflict-analyzer.md`

- [ ] **Step 1: agents 디렉토리 생성**

Run: `mkdir -p plugins/e2e-storm/agents`

- [ ] **Step 2: conflict-analyzer.md 작성**

```markdown
---
name: conflict-analyzer
description: "E2E Storm Phase 1 — 대상 프로젝트 코드를 분석하여 에이전트 간 충돌 맵(conflict-map.json)을 생성하는 에이전트. 테스트 에이전트 충돌 방지, 격리 규칙 생성에 사용."
model: sonnet
when_to_use: "E2E Storm의 storm 커맨드 Phase 1에서 호출. 직접 사용하지 않음."
tools: ["Read", "Glob", "Grep", "Write", "Bash"]
---

# Conflict Analyzer Agent

대상 프로젝트의 소스코드를 분석하여 에이전트 간 충돌을 방지하는 conflict-map.json을 생성한다.

## 입력

프롬프트로 전달받는 정보:
- `project_path`: 대상 프로젝트 경로
- `scenarios_dir`: 시나리오 디렉토리 경로
- `num_agents`: 에이전트 수
- `config`: config.json 내용 (base_url, auth_method, test_account 등)

## 분석 단계

### 1. Route Map 추출

프레임워크별 라우트를 스캔한다:
- **Next.js App Router**: `app/**/page.tsx`, `app/**/layout.tsx` glob
- **Next.js Pages**: `pages/**/*.tsx` glob
- **React Router**: `createBrowserRouter`, `<Route>` 패턴 grep
- **기타**: 메인 라우터 파일 탐색

각 라우트에서 수집:
- 경로 (path)
- 인증 요구 여부 (middleware.ts, route guard 등 확인)
- 리다이렉트 규칙
- 역할 제한 (admin, user 등)

### 2. Data Mutation Map 추출

API 엔드포인트를 스캔한다:
- **Next.js**: `app/api/**/route.ts` — export된 HTTP 메서드(GET, POST, PUT, DELETE) 확인
- **Express/Fastify**: `router.get/post/put/delete` 패턴
- **tRPC**: 프로시저 정의

각 엔드포인트에서:
- CRUD 분류 (Create/Read/Update/Delete)
- 영향받는 엔티티 (모델/테이블명)
- 부작용 (cascade delete, unique 제약, 알림 트리거 등)
- 위험도 (high: 삭제/대량변경, medium: 수정, low: 생성, none: 조회)

### 3. Auth Boundary Map 추출

인증/인가 체계를 분석한다:
- 인증 방식 감지 (Clerk, NextAuth, Firebase Auth, 직접 구현 등)
- 미들웨어에서 역할별 접근 규칙 추출
- 세션 관리 방식 (cookie, JWT, session storage)
- 테스트 계정 요구사항 도출

### 4. Shared State Map 추출

공유 상태를 식별한다:
- 전역 상태 관리 (Redux store, Zustand store, React Context)
- 브라우저 스토리지 사용 (localStorage, sessionStorage 키)
- 서버 캐시/큐 (Redis, 인메모리 캐시)
- WebSocket/실시간 연결

### 5. 충돌 쌍 식별

시나리오 파일을 읽고, 위 분석 결과와 대조하여 충돌 가능성을 식별한다:
- 같은 엔티티에 대한 생성/삭제 충돌
- 같은 계정으로의 동시 로그인
- 전역 상태를 변경하는 시나리오 간 간섭
- 순서 의존성이 있는 시나리오 쌍

### 6. 에이전트 할당 규칙 생성

격리 원칙에 따라 에이전트별 규칙을 생성한다:

| 원칙 | 적용 |
|------|------|
| Read-only 우선 | 조회 시나리오는 자유 할당 |
| Exclusive mutation | 삭제/수정은 단일 에이전트만 |
| Namespaced data | 생성 시 에이전트별 접두사 (a01_, a02_ 등) |
| Session isolation | 에이전트별 독립 계정 |
| Temporal ordering | 순서 의존 시나리오는 같은 에이전트에 배정 |

## 출력

`{scenarios_dir}/conflict-map.json`에 Write 도구로 저장:

```json
{
  "generated_at": "ISO timestamp",
  "project_analysis": {
    "framework": "next.js-app-router",
    "total_routes": 25,
    "total_api_endpoints": 40,
    "auth_method": "clerk"
  },
  "isolation_rules": {
    "browser": "each_agent_own_context",
    "accounts": {
      "agent-01": { "role": "user", "email": "...", "credential": "..." }
    }
  },
  "mutation_zones": [
    {
      "entity": "Track",
      "endpoints": ["POST /api/tracks", "DELETE /api/tracks/:id"],
      "risk": "high",
      "rule": "exclusive"
    }
  ],
  "conflict_pairs": [
    {
      "scenario_a": "S-042",
      "scenario_b": "S-108",
      "conflict": "설명",
      "resolution": "해결 방법"
    }
  ],
  "agent_assignments": {
    "agent-01": {
      "feature_area": "library-browse",
      "allowed_mutations": ["read-only"],
      "blocked_entities": [],
      "data_prefix": "a01_"
    }
  }
}
```

반드시 분석 결과의 요약을 텍스트로 출력하여 호출자에게 전달한다.
```

- [ ] **Step 3: 커밋**

```bash
git add plugins/e2e-storm/agents/conflict-analyzer.md
git commit -m "feat(storm): add conflict-analyzer agent for Phase 1"
```

---

### Task 3: error-triager 에이전트 생성

**Files:**
- Create: `plugins/e2e-storm/agents/error-triager.md`

- [ ] **Step 1: error-triager.md 작성**

```markdown
---
name: error-triager
description: "E2E Storm Phase 3 — 테스트 실행 결과의 에러를 자동 분류(TYPE-A/B/C)하고 수정 방향을 제시하는 에이전트. 에러 분석, 실패 원인 분류에 사용."
model: sonnet
when_to_use: "E2E Storm의 storm 커맨드 Phase 3에서 호출. 직접 사용하지 않음."
tools: ["Read", "Glob", "Grep", "Write"]
---

# Error Triager Agent

테스트 실행 결과에서 FAIL/SKIP 시나리오를 분석하고, 에러를 TYPE-A(시나리오 수정)/TYPE-B(앱 코드 수정)/TYPE-C(인프라 재시도)로 분류한다.

## 입력

프롬프트로 전달받는 정보:
- `cycle`: 현재 cycle 번호
- `scenarios_dir`: 시나리오 디렉토리 경로
- `project_path`: 대상 프로젝트 경로
- `round_results_dir`: 이번 라운드 결과 디렉토리 경로
- `errors_dir`: 에러 파일 디렉토리 경로

## 분류 로직

각 FAIL/SKIP 에러에 대해 순차적으로 판단한다:

### Check 1: Selector/Element 미발견

에러 메시지에 "not found", "no element", "selector" 등이 포함된 경우:
1. 시나리오의 해당 step에서 기대하는 셀렉터/텍스트를 추출
2. 프로젝트 코드에서 해당 UI 요소가 실제로 존재하는지 Grep으로 확인
   - UI 자체가 없음 → **TYPE-A** (시나리오가 미구현 기능을 테스트)
   - UI 있으나 셀렉터만 다름 → **TYPE-A** (셀렉터 수정)

### Check 2: HTTP 에러 (4xx/5xx)

에러 메시지에 HTTP 상태 코드가 포함된 경우:
- **404**: 라우트 존재 여부 확인
  - 라우트 없음 → **TYPE-A** (없는 페이지 테스트)
  - 라우트 있음 → **TYPE-B** (라우팅 버그)
- **401/403**: 권한 설정 확인
  - 시나리오 계정의 역할이 부족 → **TYPE-A** (권한 설정 불일치)
  - 인증 로직 자체에 버그 → **TYPE-B** (인증 버그)
- **500**: → **TYPE-B** (서버 버그)

### Check 3: 리다이렉트

예상치 못한 URL 변경이 발생한 경우:
- middleware/route guard에서 의도된 리다이렉트 → **TYPE-A** (시나리오에 인증 스텝 누락)
- 비의도적 리다이렉트 → **TYPE-B** (라우트 가드 버그)

### Check 4: Timeout

- 페이지 로딩 자체가 느림 → **TYPE-B** (성능 문제)
- wait_for 조건이 잘못됨 → **TYPE-A** (대기 조건 수정)

### Check 5: 브라우저 간섭

에러 메시지에 다른 에이전트의 동작 흔적이 있는 경우:
- 예상과 다른 페이지에 있음, 로그인 상태 변경 등 → **TYPE-C** (재시도)

### Check 6: 기타

위 어디에도 해당하지 않는 경우:
- 에러 내용을 분석하여 가장 적합한 타입으로 분류
- 판단 불가 시 → **TYPE-C** (재시도)

## 출력

`{scenarios_dir}/triage-{cycle}.json`에 Write 도구로 저장:

```json
{
  "cycle": 2,
  "generated_at": "ISO timestamp",
  "summary": {
    "type_a": 45,
    "type_b": 12,
    "type_c": 3,
    "total": 60
  },
  "items": [
    {
      "scenario_id": "S-042",
      "agent": "agent-02",
      "type": "A",
      "category": "selector_mismatch",
      "error": "원본 에러 메시지",
      "analysis": "분석 결과 설명",
      "fix_target": "scenario",
      "fix_hint": "구체적 수정 방향",
      "fix_files": []
    },
    {
      "scenario_id": "S-108",
      "agent": "agent-05",
      "type": "B",
      "category": "redirect_bug",
      "error": "원본 에러 메시지",
      "analysis": "분석 결과 설명",
      "fix_target": "app_code",
      "fix_hint": "구체적 수정 방향",
      "fix_files": ["src/middleware.ts"]
    }
  ]
}
```

반드시 분류 요약을 텍스트로 출력하여 호출자에게 전달한다:
```
Triage 완료: TYPE-A {N}건 (시나리오 수정), TYPE-B {N}건 (앱 코드 수정), TYPE-C {N}건 (재시도)
```
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/agents/error-triager.md
git commit -m "feat(storm): add error-triager agent for Phase 3"
```

---

### Task 4: auto-fixer 에이전트 생성

**Files:**
- Create: `plugins/e2e-storm/agents/auto-fixer.md`

- [ ] **Step 1: auto-fixer.md 작성**

```markdown
---
name: auto-fixer
description: "E2E Storm Phase 4 — triage 결과를 바탕으로 시나리오 또는 앱 코드를 자동 수정하는 에이전트. 테스트 실패 자동 수정, 시나리오 재생성에 사용."
model: opus
when_to_use: "E2E Storm의 storm 커맨드 Phase 4에서 호출. 직접 사용하지 않음."
tools: ["Read", "Edit", "Write", "Glob", "Grep", "Bash"]
---

# Auto-Fixer Agent

triage 결과를 바탕으로 TYPE-A(시나리오) 및 TYPE-B(앱 코드) 문제를 자동 수정한다.

## 입력

프롬프트로 전달받는 정보:
- `cycle`: 현재 cycle 번호
- `scenarios_dir`: 시나리오 디렉토리 경로
- `project_path`: 대상 프로젝트 경로 (worktree 경로)
- `triage_file`: triage-{cycle}.json 경로
- `app_code_fix_allowed`: 앱 코드 수정 허용 여부 (boolean)
- `conflict_map_file`: conflict-map.json 경로

## 수정 전략

### TYPE-A 수정 (시나리오)

1. triage의 각 TYPE-A 항목을 읽는다
2. 해당 시나리오가 포함된 에이전트 JSON 파일을 읽는다
3. `fix_hint`와 프로젝트 코드를 참조하여 시나리오를 수정한다:
   - **selector_mismatch**: 실제 코드에서 올바른 셀렉터를 찾아 교체
   - **missing_ui**: 시나리오의 steps를 현재 UI에 맞게 재작성
   - **auth_mismatch**: preconditions와 steps에 올바른 인증 스텝 추가
   - **wait_condition**: wait_for 조건을 현실에 맞게 수정
4. 수정된 시나리오를 원본 파일에 덮어쓴다 (Edit 도구 사용)
5. conflict-map의 isolation 규칙이 유지되는지 확인

### TYPE-B 수정 (앱 코드)

`app_code_fix_allowed`가 true일 때만 수행한다.

1. triage의 각 TYPE-B 항목을 읽는다
2. `fix_files`에 명시된 파일을 읽는다
3. `fix_hint`를 참조하여 최소한의 수정을 적용한다:
   - 수정 범위를 해당 버그에만 한정
   - 관련 없는 코드 리팩토링 금지
   - 기존 코드 스타일 준수
4. Edit 도구로 수정 적용 (worktree 내 파일만)

### TYPE-C 처리

TYPE-C 항목은 수정하지 않고, 재시도 목록으로 반환한다.

## 수정 원칙

- **최소 변경**: 문제를 해결하는 최소한의 수정만 적용
- **격리 유지**: conflict-map의 isolation 규칙을 훼손하지 않음
- **한 항목씩**: 각 triage 항목을 개별적으로 수정 (연쇄 영향 최소화)
- **앱 코드 보호**: worktree 바깥 파일은 절대 수정하지 않음

## 출력

수정 완료 후 텍스트로 요약을 출력한다:

```
Auto-Fix 완료 (Cycle {N}):
  TYPE-A 수정: {N}건 (시나리오 {N}개 파일 변경)
  TYPE-B 수정: {N}건 (앱 코드 {N}개 파일 변경)
  TYPE-C 재시도: {N}건
  변경 파일 목록:
    - scenarios/agent-02-track-upload.json (3개 시나리오 수정)
    - src/middleware.ts (admin 라우트 가드 수정)
```

git add/commit은 수행하지 않는다 — 호출자(storm 커맨드)가 커밋을 관리한다.
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/agents/auto-fixer.md
git commit -m "feat(storm): add auto-fixer agent for Phase 4"
```

---

### Task 5: setup-storm-loop.sh 스크립트 생성

**Files:**
- Create: `plugins/e2e-storm/scripts/setup-storm-loop.sh` (기존 `setup-storm-loop.sh`는 execute용이므로 별도 파일 `setup-storm-cycle.sh`로 생성)

이름 충돌을 피하기 위해 `setup-storm-cycle.sh`로 생성한다.

- [ ] **Step 1: setup-storm-cycle.sh 작성**

```bash
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

# 인터랙티브 모드 플래그: 필수 정보가 누락되면 AI가 질문하도록 표시
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
- 에이전트의 conflict-analyzer.md 내용을 프롬프트에 포함
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
```

- [ ] **Step 2: 실행 권한 부여 및 검증**

Run: `chmod +x plugins/e2e-storm/scripts/setup-storm-cycle.sh && bash plugins/e2e-storm/scripts/setup-storm-cycle.sh --help`

Expected: 도움말 출력 확인

- [ ] **Step 3: 커밋**

```bash
git add plugins/e2e-storm/scripts/setup-storm-cycle.sh
git commit -m "feat(storm): add setup-storm-cycle.sh loop initializer"
```

---

### Task 6: storm.md 커맨드 생성

**Files:**
- Create: `plugins/e2e-storm/commands/storm.md`

- [ ] **Step 1: storm.md 작성**

```markdown
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
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/commands/storm.md
git commit -m "feat(storm): add /e2e-storm:storm command"
```

---

### Task 7: stop-hook.sh 확장 (watchdog + storm 루프 지원)

**Files:**
- Modify: `plugins/e2e-storm/hooks/stop-hook.sh`

- [ ] **Step 1: stop-hook.sh에 storm 루프 + watchdog 로직 추가**

기존 execute 루프 (`e2e-storm-loop.local.md`) 처리 이후에, storm 루프 (`e2e-storm-storm-loop.local.md`) 처리와 heartbeat 체크를 추가한다.

기존 파일의 **맨 앞** `STATE_FILE=".claude/e2e-storm-loop.local.md"` 아래에 storm 루프 파일도 확인하는 로직을 추가:

```bash
# 기존 코드 끝 (exit 0 직전)에 아래를 삽입하지 말고,
# 대신 파일 시작 부분에서 STATE_FILE을 결정하는 로직으로 변경:

# --- 파일 시작 부분 변경 ---
# 기존:
#   STATE_FILE=".claude/e2e-storm-loop.local.md"
#   if [[ ! -f "$STATE_FILE" ]]; then exit 0; fi
#
# 변경:
STATE_FILE=""
HEARTBEAT_SCRIPT=""

# storm 루프 우선 확인
if [[ -f ".claude/e2e-storm-storm-loop.local.md" ]]; then
  STATE_FILE=".claude/e2e-storm-storm-loop.local.md"
  HEARTBEAT_SCRIPT="$(dirname "$0")/../scripts/heartbeat.sh"
elif [[ -f ".claude/e2e-storm-loop.local.md" ]]; then
  STATE_FILE=".claude/e2e-storm-loop.local.md"
fi

if [[ -z "$STATE_FILE" ]]; then
  exit 0
fi
```

파일 끝의 `exit 0` 직전에 heartbeat 체크를 추가:

```bash
# --- Watchdog: Heartbeat 체크 (storm 루프 전용) ---
if [[ -n "$HEARTBEAT_SCRIPT" ]] && [[ -f "$HEARTBEAT_SCRIPT" ]]; then
  HEARTBEAT_STATUS=$(bash "$HEARTBEAT_SCRIPT" check | head -1)
  if [[ "$HEARTBEAT_STATUS" == "stale" ]]; then
    # recovery 시도 횟수 확인 (state.json에서)
    STORM_STATE_DIR=$(echo "$PROMPT_TEXT" | grep -o 'SCENARIOS_DIR: [^ ]*' | head -1 | cut -d' ' -f2)
    if [[ -n "$STORM_STATE_DIR" ]] && [[ -f "$STORM_STATE_DIR/state.json" ]]; then
      RECOVERY_ATTEMPTS=$(jq -r '.recovery.attempts // 0' "$STORM_STATE_DIR/state.json")
      MAX_RECOVERY=$(jq -r '.recovery.max_attempts // 3' "$STORM_STATE_DIR/state.json")
      if [[ $RECOVERY_ATTEMPTS -ge $MAX_RECOVERY ]]; then
        echo "🛑 E2E Storm: 복구 시도 ${RECOVERY_ATTEMPTS}회 초과. 루프 종료."
        rm -f "$STATE_FILE"
        bash "$HEARTBEAT_SCRIPT" clean
        exit 0
      fi
      # recovery 횟수 증가
      jq ".recovery.attempts = $((RECOVERY_ATTEMPTS + 1))" "$STORM_STATE_DIR/state.json" > "$STORM_STATE_DIR/state.json.tmp"
      mv "$STORM_STATE_DIR/state.json.tmp" "$STORM_STATE_DIR/state.json"
    fi
    STALE_INFO=$(bash "$HEARTBEAT_SCRIPT" check | tail -1)
    STALE_PHASE=$(echo "$STALE_INFO" | jq -r '.phase // "unknown"')
    STALE_CYCLE=$(echo "$STALE_INFO" | jq -r '.cycle // 0')
    SYSTEM_MSG="⚠️ E2E Storm 루프가 Phase $STALE_PHASE, Cycle $STALE_CYCLE에서 중단 감지됨. state.json을 읽고 해당 Phase부터 재개하라."
  fi
fi
```

- [ ] **Step 2: 전체 stop-hook.sh를 재작성**

기존 로직을 유지하면서 위 변경사항을 통합한 전체 파일을 Edit 도구로 수정한다. 핵심 변경:

1. `STATE_FILE` 결정 로직을 storm/execute 양쪽 모두 지원하도록 변경
2. completion promise를 `STORM_CYCLE_COMPLETE` / `ALL_SCENARIOS_VERIFIED` 양쪽 모두 확인
3. heartbeat 체크 및 복구 로직 추가
4. 복구 실패 시 루프 중단

- [ ] **Step 3: 검증**

Run: `bash -n plugins/e2e-storm/hooks/stop-hook.sh`

Expected: syntax 에러 없음

- [ ] **Step 4: 커밋**

```bash
git add plugins/e2e-storm/hooks/stop-hook.sh
git commit -m "feat(storm): extend stop-hook with watchdog heartbeat and storm loop support"
```

---

### Task 8: hooks.json 업데이트

**Files:**
- Modify: `plugins/e2e-storm/hooks/hooks.json`

- [ ] **Step 1: hooks.json 설명 업데이트**

```json
{
  "description": "E2E Storm stop hook — execute 루프(ralph-loop) 및 storm 루프(자율 테스트-수정 반복) 지원, watchdog heartbeat 포함",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/hooks/hooks.json
git commit -m "feat(storm): update hooks.json description for storm loop"
```

---

### Task 9: cancel.md 확장

**Files:**
- Modify: `plugins/e2e-storm/commands/cancel.md`

- [ ] **Step 1: storm 루프 파일도 정리하도록 확장**

```markdown
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
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/commands/cancel.md
git commit -m "feat(storm): extend cancel to handle storm loop and heartbeat cleanup"
```

---

### Task 10: execute.md에 격리 규칙 지원 추가

**Files:**
- Modify: `plugins/e2e-storm/commands/execute.md`

- [ ] **Step 1: 에이전트 프롬프트 템플릿에 isolation 규칙 추가**

execute.md의 에이전트 프롬프트 섹션(`### 2. 에이전트 병렬 Spawn`)에 isolation 규칙을 추가한다:

기존 에이전트 프롬프트 템플릿 뒤에 추가:

```
## 격리 규칙 (conflict-map이 있는 경우)

{scenarios_dir}/conflict-map.json이 존재하면:
1. 해당 에이전트의 agent_assignments를 읽는다
2. 에이전트 프롬프트에 아래 내용을 추가한다:

```
## 격리 규칙
- 데이터 접두사: {data_prefix} — 새 데이터 생성 시 이 접두사를 이름에 포함
- 허용 변이: {allowed_mutations} — 이 목록에 없는 데이터 변경 금지
- 차단 엔티티: {blocked_entities} — 이 엔티티에 대한 변경 절대 금지
- 브라우저: 독립 컨텍스트에서 실행 — 다른 에이전트와 페이지 공유 없음
- 계정: {account} — 반드시 이 계정으로 로그인
```

3. 각 시나리오의 isolation 블록도 에이전트에 전달한다
4. 에이전트는 isolation 규칙 위반 시 해당 스텝을 SKIP 처리한다
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/commands/execute.md
git commit -m "feat(storm): add isolation rules support to execute command"
```

---

### Task 11: generate.md에 conflict-map 주입 Phase 추가

**Files:**
- Modify: `plugins/e2e-storm/commands/generate.md`

- [ ] **Step 1: Phase 6 이후에 Phase 7(Conflict Analysis) 추가**

generate.md의 `## Phase 6: 검증` 뒤, `## 출력 구조` 앞에 추가:

```markdown
---

## Phase 7: Conflict Analysis & Isolation 주입 (선택)

conflict-map.json이 이미 존재하거나, storm 루프에서 호출된 경우:

1. conflict-map.json을 읽는다
2. 각 에이전트 시나리오 파일에 isolation 블록을 주입한다:

```json
{
  "scenario_id": "S-042",
  "isolation": {
    "data_prefix": "a02_",
    "account": "test-agent02@...",
    "allowed_mutations": ["Track:create"],
    "browser_context": "isolated"
  }
}
```

3. agent_assignments에 따라 시나리오를 재배정한다:
   - exclusive mutation 시나리오는 해당 에이전트에만 배정
   - conflict_pairs의 충돌 시나리오를 같은 에이전트로 이동하거나 순서 보장

이 Phase는 conflict-map.json이 없으면 건너뛴다.
```

- [ ] **Step 2: 출력 구조에 conflict-map.json 추가**

기존 출력 구조에 추가:

```
{output}/
├── config.json
├── feature-catalog.json
├── personas.json
├── index.json
├── conflict-map.json       # Phase 7에서 생성 (선택)
└── scenarios/
```

- [ ] **Step 3: 커밋**

```bash
git add plugins/e2e-storm/commands/generate.md
git commit -m "feat(storm): add conflict-map injection phase to generate command"
```

---

### Task 12: plugin.json 업데이트

**Files:**
- Modify: `plugins/e2e-storm/.claude-plugin/plugin.json`

- [ ] **Step 1: 버전 및 설명 업데이트**

```json
{
  "name": "e2e-storm",
  "description": "E2E Test Storm — Playwright 기반 프론트엔드 자동 E2E 테스트. 페르소나/시나리오 생성, 병렬 에이전트 실행, 자율 테스트-수정 반복 루프(storm) 지원.",
  "version": "2.0.0"
}
```

- [ ] **Step 2: 커밋**

```bash
git add plugins/e2e-storm/.claude-plugin/plugin.json
git commit -m "feat(storm): bump version to 2.0.0 with storm loop feature"
```

---

### Task 13: 통합 검증

- [ ] **Step 1: 파일 구조 확인**

Run: `find plugins/e2e-storm -type f | sort`

Expected:
```
plugins/e2e-storm/.claude-plugin/plugin.json
plugins/e2e-storm/agents/auto-fixer.md
plugins/e2e-storm/agents/conflict-analyzer.md
plugins/e2e-storm/agents/error-triager.md
plugins/e2e-storm/commands/cancel.md
plugins/e2e-storm/commands/execute.md
plugins/e2e-storm/commands/generate.md
plugins/e2e-storm/commands/storm.md
plugins/e2e-storm/hooks/hooks.json
plugins/e2e-storm/hooks/stop-hook.sh
plugins/e2e-storm/scripts/heartbeat.sh
plugins/e2e-storm/scripts/setup-storm-cycle.sh
plugins/e2e-storm/scripts/setup-storm-loop.sh
```

- [ ] **Step 2: 셸 스크립트 구문 검증**

Run:
```bash
bash -n plugins/e2e-storm/hooks/stop-hook.sh && \
bash -n plugins/e2e-storm/scripts/heartbeat.sh && \
bash -n plugins/e2e-storm/scripts/setup-storm-cycle.sh && \
echo "All scripts OK"
```

Expected: `All scripts OK`

- [ ] **Step 3: JSON 구문 검증**

Run:
```bash
jq '.' plugins/e2e-storm/.claude-plugin/plugin.json > /dev/null && \
jq '.' plugins/e2e-storm/hooks/hooks.json > /dev/null && \
echo "All JSON OK"
```

Expected: `All JSON OK`

- [ ] **Step 4: 플러그인 리로드 확인**

사용자에게 `/reload-plugins` 실행을 요청한다. storm 커맨드와 3개 에이전트가 등록되었는지 확인한다.

- [ ] **Step 5: 최종 커밋 (필요 시)**

누락된 파일이 있으면 추가하고 커밋한다.
