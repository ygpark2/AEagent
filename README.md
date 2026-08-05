# 자율 진화형 에이전트 (Autonomous Evolutionary Agent) 🧬

엘릭서(Elixir/OTP) 기반의 **Outcome-Driven Agent Graph** 아키텍처를 채택하여, 고정된 명령을 수행하는 것을 넘어 스스로 사고하고, 결과를 검증하며, 경험을 통해 진화하는 차세대 인공지능 에이전트 시스템입니다.

## 🌟 핵심 아키텍처 (Key Pillars)

### 1. 계층적 인지 시스템 (Hierarchical Cognitive Architecture)
에이전트의 인지 부하와 작업 복잡도를 고려하여 노드를 4대 계층으로 구조화했습니다.
- **L1: Brain (사고 및 생성)**: `thinker`(단일 사고), `collaborator`(다수 페르소나 협업/토론)
- **L2: Hands (실행 및 도구)**: `executor`(도구 사용), `skill_selector`(기술 동적 선택)
- **L3: Eyes (성찰 및 검증)**: `critic`(품질 검토 및 비판적 분석)
- **L4: Nerve (제어 및 보고)**: `router`(경로 제어), `delegator`(위임), `reporter`(최종 보고)

### 2. 자율 설계자 (Strategic Architect)
- 사용자의 미션을 분석하여 실시간으로 최적의 **에이전트 그래프(Agent Graph)**를 설계합니다.
- 계층적 노드 구조를 바탕으로 작업 난이도에 따라 저비용 노드와 고비용 협업 노드를 전략적으로 배치합니다.

### 3. 결과 중심 엔진 (Outcome-Driven Engine)
- 단순히 단계를 밟는 것이 아니라, **성공 기준(Outcome)**을 달성할 때까지 스스로 경로를 수정합니다.
- `critic` 계층을 통한 비판적 검토와 피드백 수용으로 자가 수정 루프를 수행합니다.

### 4. 시맨틱 메모리 및 자율 진화 (Semantic Memory & Evolution)
- **로컬 RAG 통합**: Nx/Bumblebee를 사용하여 실행 이력을 벡터로 임베딩하고 시맨틱 검색을 수행합니다.
- **A/B 테스트 및 자동 롤백**: 실험적 전략의 성능(Fitness Score)을 실시간 평가하여 미달 시 즉시 폐기하고 검증된 전략으로 복구합니다.

### 5. 지능형 정책 가드레일 (Multi-policy Gatekeeper)
- 안전(Safety), 예산(Budget), 도메인(Domain) 정책을 통해 에이전트의 자율성을 통제합니다.
- 개인정보 보호, 파괴적 의도 차단, 예산 초과 방지 기능을 갖추고 있습니다.

## 🛠️ 기술 스택 (Tech Stack)
- **Language**: Elixir / OTP (고도의 병렬성 및 내결함성)
- **Intelligence**: Anthropic Claude / OpenAI / Google Gemini (통합 LLM 레이어)
- **Machine Learning**: Nx / Bumblebee (로컬 텍스트 임베딩 및 벡터 연산)
- **Observability**: OpenTelemetry / Jaeger / Honeycomb (실행 트레이싱 시각화)
- **Database**: PostgreSQL / SQLite (Long-term Memory 저장소)
- **Framework**: Phoenix LiveView (실시간 모니터링 및 인터랙션)

## 🚀 시작하기
```bash
# 의존성 설치
mix deps.get

# 환경 변수 준비
cp .env-sample .env

# 데이터베이스 준비
mix ecto.setup

# 에이전트 가동
mix phx.server
```

## 현재 구현 상태
- **관측성 강화**: OpenTelemetry 도입으로 LLM 호출 및 도구 실행의 전체 흐름을 시각화합니다.
- **동적 확장**: 런타임에 MCP(Model Context Protocol) 서버를 동적으로 등록/해제하여 도구 세트를 실시간 확장합니다.
- **안전 제어**: 위험 툴(`execute_command` 등)은 사용자 승인 후 실행되며, PII 탐지 정책이 적용됩니다.
- **진화 전략**: 성공 이력 중 유사 작업을 시맨틱 검색하여 최적의 전략을 자동 도출합니다.

## 💻 CLI 사용법
웹 UI 없이도 실행을 만들고 추적할 수 있습니다.

```bash
# 대화형 CLI 시작
mix agent.chat

# 실행 생성
mix agent.run "최신 아키텍처 요약보고서 작성"

# 진화 전략 조회
mix agent.strategies --domain general
```

### Durable Goal 프로세서

Goal은 한 번의 실행이 아니라, 여러 이벤트와 실행을 통해 달성하는 지속적인 목적입니다.
Goal 정의, 이벤트, 실행 시도, 완료 검증 결과가 DB에 저장됩니다.

```bash
# Goal 생성
mix agent.goal create release-readiness "배포 가능한 상태를 유지한다" \
  --goal-type ongoing --autonomy-level supervised

# Goal 목록 조회
mix agent.goal list

# Goal 이벤트 발생
mix agent.goal trigger release-readiness work_item.created \
  --payload '{"source":"monitor","severity":"high"}'
```

API로는 인증된 `/api/v1/goals`와 `/api/v1/goals/:id/events`를 사용할 수 있고,
외부 시스템은 `WEBHOOK_SHARED_SECRET`을 사용하는
`POST /api/v1/webhooks/goals/:id/events`로 이벤트를 보낼 수 있습니다.
`idempotency_key`를 보내면 동일 이벤트의 중복 실행을 방지합니다.

interval Goal은 다음과 같이 정의할 수 있습니다.

```json
{
  "name": "hourly-health-check",
  "objective": "서비스 상태를 확인하고 이상이 있으면 보고한다",
  "trigger": {"type": "interval", "every_seconds": 3600},
  "success_criteria": {"type": "execution_status", "value": "succeeded"}
}
```

이제 **자율 진화형 에이전트**는 당신의 가장 똑똑하고 신뢰할 수 있는 파트너가 될 것입니다.
