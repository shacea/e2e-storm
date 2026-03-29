# E2E Storm Loop — 자율 테스트-수정 반복 루프 설계

> 날짜: 2026-03-29
> 상태: 승인됨

## 1. 개요

E2E Storm에 **자율 테스트-수정 반복 루프**를 추가한다. 핵심 아이디어:

- 테스트 실행 → 에러 취합 → 자동 분류/수정 → 커밋 → 재테스트 반복
- 메트릭(pass rate) 기반 keep/discard 자동 판정 (autoresearch 기법)
- git worktree 격리로 main 브랜치 절대 보호 (ralph-md 기법)
- 에이전트 간 충돌을 코드 분석으로 사전 차단
- Watchdog으로 멈춘 루프 자동 복구

외부 플러그인 의존 없이 e2e-storm 단독으로 동작한다.

## 2. 새 커맨드

### `/e2e-storm:storm`

```
/e2e-storm:storm [--url <URL>] [--dir <시나리오 디렉토리>] [--max-cycles 10] [--agents 10]
```

**옵션 없이 실행 시** AI가 인터랙티브하게 필요 정보를 수집:

1. "테스트할 프로젝트 URL은?" (또는 로컬 경로 자동 감지)
2. "시나리오 디렉토리가 이미 있나요?"
   - 있음 → 경로 입력
   - 없음 → `/e2e-storm:generate` 자동 실행 제안 또는 자동 생성
3. "병렬 에이전트 수? (기본: 10)"
4. "최대 반복 cycle 수? (기본: 10)"
5. "앱 코드 수정도 허용? (Y/n)"
   - Y → 대상 프로젝트 경로 확인

설정 확인 후 Phase 0부터 시작.

## 3. 전체 루프 플로우

```
Phase 0: Preflight
  ├── 대상 프로젝트에서 git worktree 생성 (e2e-storm/{날짜}-{slug} 브랜치)
  └── state.json 초기화 (cycle=0, pass_rate=0)

Phase 1: Conflict Analysis
  ├── 코드 분석 → route map, auth 체계, shared state, DB mutations 식별
  ├── conflict-map.json 생성
  └── 에이전트별 격리 규칙 할당

Phase 2: Test Execution
  ├── N개 에이전트 병렬 실행 (격리 규칙 적용)
  └── 결과 수집 → round-{N}-results.json

Phase 3: Error Triage
  ├── 에러 자동 분류 (TYPE-A/B/C)
  └── triage-{cycle}.json 출력

Phase 4: Auto-Fix + Commit
  ├── TYPE-A: 시나리오 수정/재생성
  ├── TYPE-B: 앱 코드 수정 (worktree 내에서만)
  ├── TYPE-C: 재시도 큐에 추가
  └── 커밋 생성

Phase 5: Metric Judgment
  ├── pass_rate 비교 → KEEP 또는 DISCARD
  └── consecutive_no_improve 임계값 도달 시 → Phase 6

Phase 6: PR & User Decision
  ├── gh pr create (KEEP 커밋 포함)
  ├── 사용자 알림
  └── 루프 계속 → Phase 2로 복귀
```

## 4. Conflict Analysis Engine (Phase 1)

### 4.1 분석 대상

코드에서 추출할 4가지 맵:

| 맵 | 내용 |
|----|------|
| **Route Map** | 모든 라우트 경로 + 컴포넌트, 인증 요구사항, 리다이렉트 규칙 |
| **Data Mutation Map** | API 엔드포인트별 CRUD 분류, 엔티티별 영향 범위, 부작용(cascade, unique 제약) |
| **Auth Boundary Map** | 인증 방식, 역할별 접근 범위, 세션 관리 방식 |
| **Shared State Map** | 전역 상태(Redux, Zustand 등), 브라우저 스토리지, 서버 캐시 |

### 4.2 conflict-map.json 구조

```jsonc
{
  "isolation_rules": {
    "browser": "each_agent_own_context",
    "accounts": {
      "agent-01": { "role": "user", "email": "test-agent01@...", "credential": "..." },
      "agent-02": { "role": "admin", "email": "test-agent02@...", "credential": "..." }
    }
  },
  "mutation_zones": [
    {
      "entity": "Track",
      "endpoints": ["POST /api/tracks", "DELETE /api/tracks/:id"],
      "risk": "high",
      "rule": "exclusive"
    },
    {
      "entity": "UserProfile",
      "endpoints": ["PUT /api/profile"],
      "risk": "medium",
      "rule": "namespaced"
    }
  ],
  "conflict_pairs": [
    {
      "scenario_a": "S-042: 트랙 삭제",
      "scenario_b": "S-108: 트랙 재생",
      "conflict": "A가 삭제하면 B가 재생할 트랙이 없음",
      "resolution": "서로 다른 트랙 ID 사용 또는 순서 보장"
    }
  ],
  "agent_assignments": {
    "agent-01": {
      "feature_area": "library-browse",
      "allowed_mutations": ["read-only"],
      "blocked_entities": [],
      "data_prefix": "a01_"
    },
    "agent-02": {
      "feature_area": "track-upload",
      "allowed_mutations": ["Track:create"],
      "blocked_entities": ["Track:delete"],
      "data_prefix": "a02_"
    }
  }
}
```

### 4.3 격리 할당 원칙

| 원칙 | 설명 |
|------|------|
| **Read-only 우선** | 읽기 전용 시나리오는 충돌 없으므로 자유 할당 |
| **Exclusive mutation** | 삭제/수정 시나리오는 해당 엔티티에 대해 단일 에이전트만 |
| **Namespaced data** | 생성 시나리오는 에이전트별 접두사로 데이터 격리 |
| **Session isolation** | 에이전트별 독립 브라우저 컨텍스트 + 독립 계정 |
| **Temporal ordering** | 충돌 불가피 시 순서 의존 시나리오는 같은 에이전트에 배정 |

### 4.4 시나리오 주입

conflict-map의 규칙이 각 시나리오 JSON에 `isolation` 블록으로 주입된다:

```jsonc
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

실행 시 에이전트는 `isolation` 블록을 준수하며, 위반 시 해당 스텝을 SKIP 처리.

## 5. Error Triage Engine (Phase 3)

### 5.1 분류 로직

```
에러 입력 →

1. Selector/Element 미발견?
   ├── YES → 코드에서 UI 존재 확인
   │         ├── UI 없음 → TYPE-A (시나리오 수정)
   │         └── UI 있음, 셀렉터 틀림 → TYPE-A (셀렉터 수정)
   └── NO → 다음

2. HTTP 에러 (4xx/5xx)?
   ├── 404 → 라우트 존재 확인
   │         ├── 라우트 없음 → TYPE-A
   │         └── 라우트 있음 → TYPE-B (앱 버그)
   ├── 401/403 → TYPE-A (권한 불일치) 또는 TYPE-B (인증 버그)
   └── 500 → TYPE-B (서버 버그)

3. 리다이렉트 발생?
   ├── 의도된 (로그인 필요) → TYPE-A (인증 스텝 누락)
   └── 비의도적 → TYPE-B (라우트 가드 버그)

4. Timeout?
   ├── 페이지 느림 → TYPE-B (성능 버그)
   └── 대기 조건 잘못됨 → TYPE-A (wait_for 수정)

5. 브라우저 충돌/간섭 → TYPE-C (재시도)
```

### 5.2 triage-{cycle}.json 구조

```jsonc
{
  "cycle": 2,
  "summary": { "type_a": 45, "type_b": 12, "type_c": 3, "total": 60 },
  "items": [
    {
      "scenario_id": "S-042",
      "agent": "agent-02",
      "type": "A",
      "category": "selector_mismatch",
      "error": "Selector '#create-map-btn' not found",
      "analysis": "Nexus에 맵 생성 버튼 미구현. 현재 UI는 드래그앤드롭 기반.",
      "fix_target": "scenario",
      "fix_hint": "현재 Nexus 드래그앤드롭 UI 기준으로 재작성"
    },
    {
      "scenario_id": "S-108",
      "agent": "agent-05",
      "type": "B",
      "category": "redirect_bug",
      "error": "Admin /library 접근 시 /music-manager로 강제 리다이렉트",
      "analysis": "Clerk v6 라우트 가드 admin 체크 후 불필요한 리다이렉트",
      "fix_target": "app_code",
      "fix_hint": "middleware.ts admin 라우트 가드에서 /library 예외 처리",
      "fix_files": ["src/middleware.ts"]
    }
  ]
}
```

## 6. Auto-Fix 전략 (Phase 4)

| 타입 | 대상 | 방법 | 커밋 메시지 |
|------|------|------|------------|
| TYPE-A | 시나리오 JSON | 실제 UI 스냅샷 기반 스텝 재작성 | `fix(scenarios): cycle-{N} — {요약}` |
| TYPE-B | 앱 코드 | triage의 fix_files + fix_hint 기반 최소 수정 | `fix(app): cycle-{N} — {요약}` |
| TYPE-C | 없음 | 재시도 큐에 추가, 다음 Phase 2에서 재실행 | — |

## 7. Metric Judgment (Phase 5)

### 메트릭

```
pass_rate = pass / (total - skip) × 100
```

### 판정 로직

```
current_rate = 이번 cycle pass_rate
prev_rate    = 직전 cycle pass_rate

IF current_rate > prev_rate:
  → KEEP
  → consecutive_no_improve = 0
  → 커밋 유지

ELSE IF current_rate <= prev_rate:
  → DISCARD
  → git reset --hard (이번 cycle 커밋 전부 되돌림)
  → consecutive_no_improve += 1

IF consecutive_no_improve >= no_improve_threshold (기본 3):
  → 루프 일시 중단
  → 현재까지 KEEP 커밋으로 PR 생성
  → 사용자 알림: "더 이상 개선 없음. PR #{num} 확인 바랍니다."
```

### results.tsv 로깅

```
cycle   pass_rate   total   pass   fail   skip   decision   commit
1       23.0        1000    230    519    242    keep       a1b2c3d
2       61.0        1000    610    300    90     keep       b2c3d4e
3       58.0        1000    580    350    70     discard    —
```

## 8. state.json 구조

```jsonc
{
  "branch": "e2e-storm/2026-03-29-jasonmusic",
  "worktree_path": "/tmp/e2e-storm-wt-abc123",
  "cycle": 3,
  "max_cycles": 10,
  "app_code_fix_allowed": true,
  "target_project_path": "/path/to/project",
  "phases": {
    "current": "execution",
    "last_heartbeat": "2026-03-29T14:30:00Z"
  },
  "metrics": {
    "history": [
      { "cycle": 1, "pass_rate": 23.0, "total": 1000, "pass": 230, "fail": 519, "skip": 242, "decision": "keep" },
      { "cycle": 2, "pass_rate": 61.0, "total": 1000, "pass": 610, "fail": 300, "skip": 90, "decision": "keep" }
    ],
    "consecutive_no_improve": 0,
    "no_improve_threshold": 3
  },
  "conflict_map": "conflict-map.json",
  "prs_created": ["#12", "#15"],
  "results_tsv": "results.tsv",
  "recovery": {
    "attempts": 0,
    "max_attempts": 3
  }
}
```

## 9. Watchdog (Heartbeat)

### 작동 원리

매 Phase 진입 시 heartbeat 파일 갱신:

```jsonc
// .claude/e2e-storm-heartbeat.json
{
  "phase": "execution",
  "timestamp": "2026-03-29T14:30:00Z",
  "cycle": 3
}
```

### stop-hook.sh 확장

1. 기존 로직: loop 파일 확인 → 미완료면 block + 재주입
2. 추가 로직: heartbeat 타임스탬프 확인
   - 마지막 heartbeat < 3분 → 정상, 기존 로직 수행
   - 마지막 heartbeat ≥ 3분 → 멈춤으로 판단
     - 현재 phase, cycle 정보 읽기
     - 해당 phase부터 재시작 프롬프트 주입

### 복구 프롬프트

```
E2E Storm 루프가 Phase {phase}, Cycle {cycle}에서 중단됨.
state.json을 읽고 해당 Phase부터 재개하라.
```

### 안전장치

- 같은 phase에서 3회 연속 복구 실패 → 루프 중단 + 사용자 알림
- 복구 시도 횟수를 state.json `recovery.attempts`에 기록

## 10. 파일 구조 (최종)

```
plugins/e2e-storm/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   ├── generate.md          (기존)
│   ├── execute.md           (기존, 격리 규칙 확장)
│   ├── cancel.md            (기존)
│   └── storm.md             (신규 — 통합 루프 커맨드)
├── agents/
│   ├── conflict-analyzer.md (신규 — Phase 1 충돌 분석)
│   ├── error-triager.md     (신규 — Phase 3 에러 분류)
│   └── auto-fixer.md        (신규 — Phase 4 자동 수정)
├── hooks/
│   ├── hooks.json           (기존 확장 — watchdog 추가)
│   └── stop-hook.sh         (기존 확장 — heartbeat 체크)
├── scripts/
│   ├── setup-storm-loop.sh  (기존 확장)
│   └── heartbeat.sh         (신규 — heartbeat 갱신/체크)
└── README.md
```

## 11. 기존 커맨드와의 관계

| 커맨드 | 역할 | 변경사항 |
|--------|------|----------|
| `/e2e-storm:generate` | 시나리오 생성 | conflict-map 기반 isolation 블록 주입 추가 |
| `/e2e-storm:execute` | 단일 라운드 실행 | 격리 규칙 준수 로직 추가, 독립 브라우저 컨텍스트 명시 |
| `/e2e-storm:cancel` | 루프 취소 | storm 루프도 취소 가능하도록 확장 |
| `/e2e-storm:storm` | **통합 루프 (신규)** | generate + execute + triage + fix + judgment 전체 오케스트레이션 |
