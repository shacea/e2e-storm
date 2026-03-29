---
description: "E2E Storm 시나리오를 Playwright 브라우저로 병렬 실행. ralph-loop으로 모든 시나리오 2회 연속 완전 검증까지 반복."
argument-hint: "[--agents N] [--dir PATH] [--max-iterations N]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-storm-loop.sh:*)"]
---

# E2E Storm: Execute

생성된 E2E 시나리오를 Playwright 브라우저로 병렬 실행한다.
ralph-loop 메커니즘으로 모든 시나리오가 2회 연속 완전히 테스트될 때까지 자동 반복한다.

## 사전 요구사항

- `/e2e-storm:generate`로 시나리오가 이미 생성되어 있어야 한다
- Playwright MCP 서버가 연결되어 있어야 한다 (browser_navigate 등 사용 가능)

## Ralph Loop 시작

아래 명령으로 루프를 초기화한다:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-storm-loop.sh" $ARGUMENTS
```

## 핵심 규칙 (매 라운드 반복)

### 절대 금지
- `curl`, `wget`, `fetch()`, `requests.get()` 등 HTTP 직접 호출로 테스트하는 것
- Playwright 없이 코드 분석만으로 PASS 판정하는 것
- 시나리오를 건너뛰고 PASS로 마킹하는 것

### 반드시 준수
- **Playwright MCP 도구만 사용**: `browser_navigate`, `browser_click`, `browser_fill_form`, `browser_snapshot`, `browser_press_key`, `browser_type`, `browser_hover`, `browser_wait_for`, `browser_take_screenshot`
- 실제 사람이 브라우저를 조작하듯 마우스 클릭, 키보드 입력으로 테스트
- 각 시나리오의 모든 step을 순서대로 실행
- expected_results의 각 항목을 `browser_snapshot`으로 검증
- 실패 시 `browser_take_screenshot`으로 증거 스크린샷 저장

## 매 라운드 실행 흐름

### 1. 상태 확인
`{dir}/state.json`을 읽는다. 없으면 `index.json`에서 초기 상태를 생성한다.

### 2. 에이전트 병렬 Spawn
Agent 도구로 N개 에이전트를 **동시에** spawn한다. 각 에이전트 프롬프트에 반드시 포함:

```
너는 E2E 테스트 에이전트 {NN}번이다.
반드시 Playwright MCP 도구로 실제 브라우저를 조작하여 테스트한다.

## 필수 규칙
- browser_navigate, browser_click, browser_fill_form, browser_snapshot, browser_press_key, browser_type, browser_hover, browser_wait_for, browser_take_screenshot 도구만 사용
- curl/fetch/requests 등 HTTP 직접 호출 절대 금지
- 실제 사람처럼 마우스 클릭, 키보드 입력으로 테스트
- 매 시나리오 시작 전 browser_snapshot으로 현재 상태 확인
- 실패 시 browser_take_screenshot으로 스크린샷 저장
- 시나리오 건너뛰기 금지 — 모든 시나리오를 반드시 실행

## 테스트 계정
- URL: {base_url}
- ID: {test_id}
- PW: {test_pw}

## 담당 시나리오
{시나리오 JSON 내용}

## Playwright 실행 패턴

1. browser_navigate로 base_url 접속
2. 로그인이 필요하면:
   - 로그인 버튼/링크 클릭 (browser_click)
   - ID 필드에 입력 (browser_fill_form 또는 browser_click + browser_type)
   - PW 필드에 입력
   - 제출 버튼 클릭
   - 로그인 완료 대기 (browser_wait_for)
3. 각 시나리오의 steps를 순서대로:
   - 페이지 이동 → browser_navigate(url)
   - 요소 클릭 → browser_click(selector) — 텍스트, aria-label, CSS selector 사용
   - 텍스트 입력 → browser_fill_form(selector, value)
   - 키보드 → browser_press_key(key)
   - 대기 → browser_wait_for(text|selector|url)
   - 상태 확인 → browser_snapshot() 후 DOM에서 expected_results 검증
4. 각 시나리오 결과를 기록

## 결과 저장
{results_dir}/agent-{NN}-results.json 에 Write 도구로 저장:
{
  "agent_id": N,
  "round": N,
  "tested_at": "ISO timestamp",
  "summary": { "total": N, "pass": N, "fail": N, "skip": N },
  "results": [
    {
      "id": "S001",
      "title": "제목",
      "status": "PASS|FAIL|SKIP",
      "method": "playwright",
      "details": "실행 내용 상세",
      "error": null | "에러 메시지",
      "screenshot": null | "스크린샷 경로",
      "suggested_fix": null | "수정 제안"
    }
  ]
}
```

### 2.5 격리 규칙 적용 (conflict-map이 있는 경우)

`{dir}/conflict-map.json`이 존재하면, 각 에이전트 프롬프트에 격리 규칙을 추가한다:

1. conflict-map.json의 `agent_assignments`에서 해당 에이전트의 규칙을 읽는다
2. 에이전트 프롬프트에 아래 내용을 추가한다:

```
## 격리 규칙
- 데이터 접두사: {data_prefix} — 새 데이터 생성 시 이 접두사를 이름에 포함
- 허용 변이: {allowed_mutations} — 이 목록에 없는 데이터 변경 금지
- 차단 엔티티: {blocked_entities} — 이 엔티티에 대한 변경 절대 금지
- 브라우저: 독립 컨텍스트에서 실행 — 다른 에이전트와 페이지 공유 없음
- 계정: {account} — 반드시 이 계정으로 로그인
```

3. 각 시나리오의 `isolation` 블록도 에이전트에 전달한다
4. 에이전트는 isolation 규칙 위반 시 해당 스텝을 SKIP 처리한다

### 3. 결과 수집 및 상태 업데이트

모든 에이전트 완료 후:

1. 각 `agent-{NN}-results.json`을 읽어 결과를 집계한다
2. `{dir}/state.json`을 업데이트:
   - 새 라운드 정보 추가 (total, tested, pass, fail, skip, untested)
   - 모든 시나리오가 빠짐없이 테스트되었으면 `complete: true`
   - complete가 연속 2라운드이면 `consecutive_complete_rounds` 증가
   - 하나라도 빠졌으면 `consecutive_complete_rounds = 0`
3. FAIL 시나리오를 `{dir}/errors/` 에 개별 JSON으로 저장:

```json
{
  "id": "S042",
  "title": "시나리오 제목",
  "status": "FAIL",
  "method": "playwright",
  "details": "실패 상세",
  "error": "에러 메시지",
  "screenshot": "results/round-1/screenshots/S042.png",
  "suggested_fix": "수정 제안",
  "agent_id": 3,
  "agent_name": "에이전트명"
}
```

### 4. 완료 판정

```
IF consecutive_complete_rounds >= 2:
  → 최종 결과 요약 출력
  → <promise>ALL_SCENARIOS_VERIFIED</promise> 출력
  → 루프 종료
ELSE:
  → 현재 라운드 결과 요약 출력
  → "미완료: {N}개 시나리오 재테스트 예정" 메시지
  → 종료 (ralph-loop Stop hook이 자동으로 다음 라운드 시작)
```

## 최종 결과 요약 형식

```
✅ E2E Storm 테스트 완료!

📊 최종 결과:
   총 시나리오: {N}개
   PASS: {N}개
   FAIL: {N}개

🔄 총 라운드: {N}회
📁 결과: {dir}/results/
📁 오류: {dir}/errors/
```
