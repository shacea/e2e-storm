---
description: "프론트엔드 분석 후 E2E 테스트 페르소나/시나리오 자동 생성. 프론트엔드 테스트 준비, 시나리오 생성, 페르소나 만들기 등에 사용."
argument-hint: "[--url URL] [--personas N] [--scenarios N] [--agents N] [--output DIR]"
---

# E2E Storm: Generate

프론트엔드 소스코드와 문서를 분석하여 테스트 페르소나와 시나리오를 자동 생성한다.
생성 완료 후 `/e2e-storm:execute`로 Playwright 병렬 실행할 수 있다.

## 파라미터 파싱

$ARGUMENTS 에서 아래 값을 추출한다. 누락된 필수 값은 사용자에게 질문한다:

| 파라미터 | 설명 | 기본값 |
|----------|------|--------|
| `--url` | 테스트 대상 URL | 없음 (필수) |
| `--personas` | 생성할 페르소나 수 | 100 |
| `--scenarios` | 생성할 시나리오 수 | 1000 |
| `--agents` | 병렬 에이전트 수 (시나리오 배분 단위) | 10 |
| `--output` | 출력 디렉토리 | `e2e-storm/` |

사용자에게 반드시 확인할 항목:
- 테스트 계정 정보 (ID, password, role) — 없으면 비로그인 테스트만 가능
- 인증 방식 (Clerk, NextAuth, 직접 구현 등)
- 테스트에서 제외할 영역 (외부 서비스 의존, 결제 등)

---

## Phase 1: 프론트엔드 분석

### 1.1 프레임워크 감지

프로젝트 루트에서 `package.json`을 읽고 프레임워크를 감지한다:
- Next.js (App Router / Pages Router)
- React + React Router
- Vue + Vue Router
- Angular
- 기타 SPA/MPA

### 1.2 라우트 수집

프레임워크별 라우트 탐색:
- **Next.js App Router**: `app/**/page.tsx` glob으로 수집
- **Next.js Pages**: `pages/**/*.tsx` glob으로 수집
- **React Router**: 라우트 설정 파일에서 추출
- **기타**: 메인 라우터 파일에서 추출

각 라우트에서 수집할 정보:
- 경로 (path)
- 인증 요구 여부 및 역할 제한
- 주요 컴포넌트 목록
- 사용자가 수행할 수 있는 모든 액션 (클릭, 입력, 드래그, 스크롤, 호버 등)

`docs/` 폴더에 기존 분석 문서(아키텍처, API, 컴포넌트 인벤토리)가 있으면 우선 참조하여 탐색 시간을 줄인다.

### 1.3 Feature Catalog 생성

`{output}/feature-catalog.json`:

```json
{
  "total_features": 369,
  "generated_at": "2026-03-22",
  "description": "{프로젝트명} 프론트엔드 라우트별 사용자 액션 카탈로그",
  "routes": [
    {
      "path": "/library",
      "name": "트랙 라이브러리",
      "auth_required": false,
      "role_required": null,
      "components": ["ClientLibraryPage", "LibrarySidebar", "BottomPlayer"],
      "actions": [
        "탭 전환: All / Favorites / Downloads",
        "검색창에 트랙 제목 텍스트 입력",
        "정렬 드롭다운 열기/닫기",
        "태그 필터 카테고리 확장/축소",
        "트랙 클릭하여 재생",
        "트랙 즐겨찾기 버튼 클릭",
        "무한 스크롤 — 추가 트랙 로드"
      ]
    }
  ]
}
```

---

## Phase 2: 페르소나 생성

서비스 도메인을 분석하여 이 서비스를 실제로 사용할 다양한 사용자 유형을 반영한 페르소나를 생성한다.

`{output}/personas.json`:

```json
{
  "total": 100,
  "distribution": {
    "role_categories": { "콘텐츠 크리에이터": 25, "개발자": 15, "일반 사용자": 30, "관리자": 10, "기타": 20 },
    "tech_levels": { "beginner": 30, "intermediate": 40, "advanced": 20, "expert": 10 },
    "devices": { "desktop": 50, "mobile": 30, "tablet": 20 }
  },
  "personas": [
    {
      "id": "P001",
      "name": "Alex Rivera",
      "role": "YouTube creator",
      "role_category": "콘텐츠 크리에이터",
      "tech_level": "intermediate",
      "personality": "호기심 강한 실험형, 새 기능을 적극적으로 시도",
      "use_case": "자신의 YouTube 영상에 BGM 찾기",
      "device_preference": "desktop",
      "frustration_triggers": ["느린 로딩", "복잡한 UI"],
      "goals": ["저작권 무료 음악 찾기", "장르별 탐색"]
    }
  ]
}
```

### 페르소나 원칙
- 이름은 다양한 문화적 배경을 반영 (영문)
- 역할 분포는 서비스의 실제 사용자 인구통계 반영
- tech_level: beginner 30%, intermediate 40%, advanced 20%, expert 10%
- devices: desktop 50%, mobile 30%, tablet 20%
- personality는 테스트 행동에 영향을 줄 특성 (급한 사용자, 꼼꼼한 탐색자, 초보자 등)
- frustration_triggers로 UX 문제를 조기 발견할 수 있는 단서 제공

---

## Phase 3: 시나리오 생성

Feature Catalog의 모든 액션을 커버하되, 페르소나의 관점에서 자연스러운 사용자 여정(user journey)으로 시나리오를 구성한다.

### 시나리오 분배

총 시나리오를 에이전트 수로 나누어 관련 기능별로 그룹화한다.
예: agent-01은 홈/네비게이션, agent-02는 검색/필터, agent-03은 사용자 계정 등.

### 에이전트별 시나리오 파일

`{output}/scenarios/agent-{NN}-{name}.json`:

```json
{
  "agent_id": 1,
  "agent_name": "홈페이지 & 네비게이션",
  "description": "홈페이지, 헤더/푸터 네비게이션, 반응형 레이아웃 테스트",
  "test_account": {
    "id": "testuser",
    "password": "testpass",
    "role": "admin"
  },
  "base_url": "https://example.com",
  "scenarios": [
    {
      "id": "S001",
      "title": "로그인 후 홈페이지 로딩 확인",
      "category": "홈페이지",
      "priority": "critical",
      "persona": "P001 Alex Rivera",
      "preconditions": ["로그아웃 상태"],
      "steps": [
        "base_url 접속",
        "로그인 버튼 클릭",
        "ID 입력 필드에 테스트 계정 ID 입력",
        "PW 입력 필드에 테스트 계정 비밀번호 입력",
        "로그인 제출 버튼 클릭",
        "홈페이지 메인 콘텐츠 영역이 표시될 때까지 대기",
        "헤더에 프로필 아이콘이 표시되는지 확인"
      ],
      "expected_results": [
        "로그인 성공 후 홈페이지로 리다이렉트",
        "메인 콘텐츠 영역 렌더링",
        "헤더에 프로필 아이콘 존재"
      ]
    }
  ]
}
```

### 시나리오 작성 원칙

**steps는 Playwright로 직접 실행 가능한 구체적 액션이어야 한다:**
- 좋은 예: `"헤더의 'Library' 텍스트가 있는 링크를 클릭한다"`, `"URL이 /library로 변경되었는지 확인"`
- 나쁜 예: `"라이브러리가 잘 작동하는지 확인"`, `"페이지가 정상인지 본다"`

**step 작성 시 Playwright 액션으로 변환 가능하도록:**
- 페이지 이동 → `browser_navigate(url)`
- 요소 클릭 → `browser_click(selector)` — 텍스트, role, CSS selector 중 하나 명시
- 텍스트 입력 → `browser_fill_form(selector, value)` 또는 `browser_type(text)`
- 키보드 입력 → `browser_press_key(key)`
- 대기 → `browser_wait_for(selector|text|url)`
- 상태 확인 → `browser_snapshot()` 후 DOM 검증

**priority 분포:** critical 20%, high 30%, medium 35%, low 15%

**카테고리 균형:** 기능 테스트, 네비게이션, 폼 입력, 에러 처리, 반응형, 접근성, 보안, 엣지케이스

**preconditions에 명시:** 로그인 상태, 필요한 데이터 상태, 뷰포트 크기 등

---

## Phase 4: Index 생성

`{output}/index.json`:

```json
{
  "project": "{프로젝트명} E2E Test Storm",
  "generated_at": "2026-03-22",
  "total_scenarios": 1000,
  "total_agents": 10,
  "total_personas": 100,
  "test_account": {
    "id": "testuser",
    "password": "testpass",
    "role": "admin",
    "base_url": "https://example.com"
  },
  "agents": [
    {
      "agent_id": 1,
      "file": "scenarios/agent-01-홈-네비게이션.json",
      "name": "홈페이지 & 네비게이션",
      "scenarios": "S001-S100",
      "count": 100,
      "scope": "홈페이지, 헤더/푸터 링크, 반응형 레이아웃"
    }
  ],
  "excluded": []
}
```

---

## Phase 5: Config 저장

`{output}/config.json`:

```json
{
  "base_url": "https://example.com",
  "test_account": { "id": "testuser", "password": "testpass", "role": "admin" },
  "auth_method": "clerk",
  "params": {
    "personas": 100,
    "scenarios": 1000,
    "agents": 10
  },
  "excluded_areas": [],
  "generated_at": "2026-03-22"
}
```

---

## Phase 6: 검증

생성 완료 후 반드시 검증:

1. Feature Catalog의 모든 액션이 최소 1개 시나리오에 포함되었는지
2. 모든 페르소나가 최소 1개 시나리오에 배정되었는지
3. 시나리오 ID가 연속적이고 중복 없는지
4. 에이전트별 시나리오 수가 대략 균등한지
5. steps가 Playwright로 실행 가능한 수준으로 구체적인지 (샘플 확인)

검증 결과를 사용자에게 요약 보고한다.

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

---

## 출력 구조

```
{output}/
├── config.json           # 테스트 설정
├── feature-catalog.json  # 프론트엔드 기능 카탈로그
├── personas.json         # 생성된 페르소나
├── index.json            # 시나리오 인덱스
├── conflict-map.json       # Phase 7에서 생성 (선택)
└── scenarios/
    ├── agent-01-{name}.json
    ├── agent-02-{name}.json
    └── ...
```

생성이 완료되면 사용자에게 안내한다:
```
✅ E2E Storm 시나리오 생성 완료!
   📁 출력: {output}/
   👥 페르소나: {N}개
   📋 시나리오: {N}개 ({agents}개 에이전트 분배)

   실행: /e2e-storm:execute --agents {agents}
```
