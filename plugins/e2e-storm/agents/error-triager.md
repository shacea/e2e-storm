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
