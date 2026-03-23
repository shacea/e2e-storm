# e2e-storm

[English](#english) | [한국어](#한국어)

---

## 한국어

Claude Code를 위한 **Playwright 기반 프론트엔드 자동 E2E 테스트** 플러그인.

AI가 프론트엔드를 분석하여 페르소나와 시나리오를 자동 생성하고, 병렬 에이전트가 실제 브라우저에서 사람처럼 테스트합니다.

### 주요 기능

- **프론트엔드 자동 분석**: 소스코드와 문서를 분석하여 라우트별 기능 카탈로그 생성
- **페르소나 생성**: 서비스 도메인에 맞는 다양한 사용자 유형 자동 생성
- **시나리오 생성**: Playwright로 직접 실행 가능한 구체적 테스트 시나리오 1000개+ 생성
- **병렬 브라우저 테스트**: N개 에이전트가 동시에 Playwright MCP로 실제 브라우저 조작
- **Ralph Loop 내장**: 모든 시나리오가 2회 연속 완전 검증될 때까지 자동 반복
- **오류 자동 수집**: FAIL 시나리오별 스크린샷과 에러 리포트 자동 저장

### 설치

#### 플러그인 마켓플레이스에서 설치 (권장)

```
/plugin marketplace add shacea/e2e-storm
/plugin install e2e-storm
```

#### 수동 설치 (settings.json)

`~/.claude/settings.json`에 아래 내용을 추가:

```json
{
  "enabledPlugins": {
    "e2e-storm@e2e-storm": true
  },
  "extraKnownMarketplaces": {
    "e2e-storm": {
      "source": {
        "source": "github",
        "repo": "shacea/e2e-storm"
      },
      "autoUpdate": true
    }
  }
}
```

Claude Code를 재시작하면 자동으로 플러그인이 로드됩니다.

### 사용법

#### 1단계: 시나리오 생성

```
/e2e-storm:generate --url https://example.com --personas 100 --scenarios 1000 --agents 10
```

| 파라미터 | 설명 | 기본값 |
|----------|------|--------|
| `--url` | 테스트 대상 URL | 필수 |
| `--personas` | 생성할 페르소나 수 | 100 |
| `--scenarios` | 생성할 시나리오 수 | 1000 |
| `--agents` | 병렬 에이전트 수 | 10 |
| `--output` | 출력 디렉토리 | `e2e-storm/` |

생성 과정:
1. 프론트엔드 소스코드 분석 → Feature Catalog 생성
2. 서비스 도메인에 맞는 페르소나 자동 생성
3. 모든 기능을 커버하는 시나리오 생성
4. 에이전트별 균등 배분

#### 2단계: 테스트 실행

```
/e2e-storm:execute --agents 10
```

| 파라미터 | 설명 | 기본값 |
|----------|------|--------|
| `--agents` | 병렬 에이전트 수 | 10 |
| `--dir` | 시나리오 디렉토리 | `e2e-storm/` |
| `--max-iterations` | 최대 반복 수 | 무제한 |

실행 과정:
1. Ralph Loop 자동 시작
2. N개 에이전트가 Playwright MCP로 병렬 브라우저 테스트
3. 매 라운드 빠진 테스트 자동 감지
4. **2회 연속 모든 시나리오 완전 검증 시 자동 종료**

#### 3단계: 취소 (필요 시)

```
/e2e-storm:cancel
```

### 출력 구조

```
e2e-storm/
├── config.json           # 테스트 설정
├── feature-catalog.json  # 프론트엔드 기능 카탈로그
├── personas.json         # 생성된 페르소나
├── index.json            # 시나리오 인덱스
├── scenarios/            # 에이전트별 시나리오
│   ├── agent-01-홈-네비게이션.json
│   ├── agent-02-검색-필터.json
│   └── ...
├── state.json            # 테스트 실행 상태
├── results/              # 라운드별 결과
│   ├── round-1/
│   │   ├── agent-01-results.json
│   │   └── ...
│   └── round-2/
└── errors/               # 실패 시나리오 개별 리포트
    ├── S042-에러.json
    └── ...
```

### 핵심 원칙

- **실제 브라우저 테스트**: Playwright MCP로 마우스 클릭/키보드 입력 (curl/requests 절대 금지)
- **Ralph Loop 내장**: 별도 ralph-loop 플러그인 불필요, 독립 동작
- **완료 보장**: 2회 연속 전체 PASS 확인 후 자동 종료
- **병렬 실행**: N개 에이전트가 시나리오를 분배하여 동시 실행

### 요구사항

- Claude Code v1.0.80+
- Playwright MCP 플러그인 (`playwright@claude-plugins-official`)

### 라이선스

MIT

---

## English

**Playwright-based automated frontend E2E testing** plugin for Claude Code.

AI analyzes the frontend to auto-generate personas and scenarios, then parallel agents test in real browsers like humans.

### Key Features

- **Auto Frontend Analysis**: Analyzes source code and docs to create route-level feature catalogs
- **Persona Generation**: Auto-generates diverse user types matching the service domain
- **Scenario Generation**: Creates 1000+ concrete test scenarios executable by Playwright
- **Parallel Browser Testing**: N agents simultaneously operate real browsers via Playwright MCP
- **Built-in Ralph Loop**: Auto-repeats until all scenarios pass verification 2 consecutive times
- **Auto Error Collection**: Auto-saves screenshots and error reports per failed scenario

### Installation

#### From Plugin Marketplace (Recommended)

```
/plugin marketplace add shacea/e2e-storm
/plugin install e2e-storm
```

#### Manual Installation (settings.json)

Add the following to `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "e2e-storm@e2e-storm": true
  },
  "extraKnownMarketplaces": {
    "e2e-storm": {
      "source": {
        "source": "github",
        "repo": "shacea/e2e-storm"
      },
      "autoUpdate": true
    }
  }
}
```

Restart Claude Code and the plugin will be loaded automatically.

### Usage

#### Step 1: Generate Scenarios

```
/e2e-storm:generate --url https://example.com --personas 100 --scenarios 1000 --agents 10
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--url` | Target URL | Required |
| `--personas` | Number of personas | 100 |
| `--scenarios` | Number of scenarios | 1000 |
| `--agents` | Number of parallel agents | 10 |
| `--output` | Output directory | `e2e-storm/` |

#### Step 2: Execute Tests

```
/e2e-storm:execute --agents 10
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--agents` | Number of parallel agents | 10 |
| `--dir` | Scenarios directory | `e2e-storm/` |
| `--max-iterations` | Max iterations | Unlimited |

#### Step 3: Cancel (if needed)

```
/e2e-storm:cancel
```

### Requirements

- Claude Code v1.0.80+
- Playwright MCP plugin (`playwright@claude-plugins-official`)

### License

MIT
