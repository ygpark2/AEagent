<div align="center">
  
# Autonomous Evolutionary Agent 🧬

[English 🇬🇧](README_en.md) | [Korean  🇰🇷](README.md)
</div>

Adopting an Elixir/OTP-based **Outcome-Driven Agent Graph** architecture, this next-generation AI agent system goes beyond merely executing fixed commands; it thinks autonomously, validates its own results, and evolves through experience.

## 🌟 Key Pillars

### 1. Hierarchical Cognitive Architecture
Nodes are structured into four distinct layers to effectively manage the agent's cognitive load and task complexity.
- **L1: Brain (Thinking & Generation)**: `thinker` (singular thought process), `collaborator` (multi-persona collaboration/discussion)
- **L2: Hands (Execution & Tools)**: `executor` (tool utilization), `skill_selector` (dynamic skill selection)
- **L3: Eyes (Reflection & Validation)**: `critic` (quality review and critical analysis)
- **L4: Nerve (Control & Reporting)**: `router` (path control), `delegator` (task delegation), `reporter` (final reporting)

### 2. Strategic Architect
- Analyzes user missions to design the optimal **Agent Graph** in real-time.
- Based on the hierarchical node structure, it strategically deploys low-cost nodes versus high-cost collaborative nodes according to the difficulty of the task.

### 3. Outcome-Driven Engine
- Rather than simply following a linear sequence of steps, it autonomously adjusts its path until the defined **Success Criteria (Outcome)** are achieved.
- It executes a self-correction loop through critical review via the `critic` layer and by incorporating feedback. ### 4. Semantic Memory & Autonomous Evolution
- **Local RAG Integration**: Utilizes Nx/Bumblebee to embed execution history into vectors and perform semantic search.
- **A/B Testing & Automated Rollback**: Real-time evaluation of experimental strategies' performance (Fitness Score); if performance falls short, the strategy is immediately discarded and the system reverts to a proven strategy.

### 5. Intelligent Policy Guardrails (Multi-policy Gatekeeper)
- Governs agent autonomy through Safety, Budget, and Domain policies.
- Features include privacy protection, blocking of destructive intent, and prevention of budget overruns.

## 🛠️ Tech Stack
- **Language**: Elixir / OTP (High concurrency & Fault tolerance)
- **Intelligence**: Anthropic Claude / OpenAI / Google Gemini (Integrated LLM Layer)
- **Machine Learning**: Nx / Bumblebee (Local text embedding & Vector operations)
- **Observability**: OpenTelemetry / Jaeger / Honeycomb (Execution trace visualization)
- **Database**: PostgreSQL / SQLite (Long-term Memory storage)
- **Framework**: Phoenix LiveView (Real-time monitoring & Interaction)

## 🚀 Getting Started
```bash
# Install dependencies
mix deps.get

# Prepare environment variables
cp .env-sample .env

# Prepare database
mix ecto.setup

# Start the agent
mix phx.server
```

## Optional Provider: OrcaRouter

OrcaRouter uses the existing OpenAI-compatible API provider. Set these values in your environment configuration:

```dotenv
AGENT_RUNTIME_TYPE=api
AGENT_BASE_URL=https://api.orcarouter.ai/v1
AGENT_API_KEY=<your-orcarouter-api-key>
AGENT_MODEL=<model-id-from-orcarouter>
AGENT_STREAM=false
CLIPROXYAPI=false
```

Get a key through the [official documentation](https://docs.orcarouter.ai/introduction) and choose an available ID from the [model catalog](https://docs.orcarouter.ai/getting-started/models). Restart after changing configuration; releases using build-time configuration require rebuilding.

Set `AGENT_STREAM=true` for incremental API responses in the agent dashboard. Tool arguments are assembled before execution, and failed partial streams are not automatically replayed. Existing approval rules still apply. To revert, restore your previous provider configuration and disable streaming.

Live OrcaRouter validation and partner approval are pending. No referral link has been added. Local tests do not certify every upstream model. `cost_usd` remains AEagent's configured estimate, not an OrcaRouter billing receipt. See the [integration checklist](docs/orcarouter-integration.md).

## Current Implementation Status
- **Enhanced Observability**: Adoption of OpenTelemetry to visualize the entire flow of LLM calls and tool executions.
- **Dynamic Extensibility**: Dynamically registers and unregisters MCP (Model Context Protocol) servers at runtime to expand the toolset in real-time.
- **Safety Controls**: Risky tools (such as `execute_command`) are executed only after user approval, and PII detection policies are applied.
- **Evolution Strategy**: It automatically derives the optimal strategy by performing a semantic search for similar tasks within its history of successful executions.

## 💻 CLI Usage
You can create and track runs even without the web UI.

```bash
# Start interactive CLI
mix agent.chat

# Create a run
mix agent.run "Draft a summary report on the latest architecture"

# View evolution strategies
mix agent.strategies --domain general
```

Now, the **Self-Evolving Agent** will become your smartest and most trusted partner.
