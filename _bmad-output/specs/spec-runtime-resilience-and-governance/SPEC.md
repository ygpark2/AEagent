---
id: SPEC-runtime-resilience-and-governance
companions:
  - ../../planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md
sources:
  - TODO.txt
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Runtime Resilience and Tool Governance Hardening

## Why

The `aeagent` system provides autonomous multi-tier cognitive agent execution, but gaps in execution lifecycle management and tool security undermine its reliability in production. Specifically, executions requiring human approval terminate in disconnected deadlocks with no automatic resumption path; concurrent DAG fan-in branches overwrite shared context outputs and artifacts; and external MCP tools lack circuit breaking and granular capability boundaries. Closing these operational gaps is required to transform `aeagent` into a robust, durable, and production-ready autonomous agent platform.

## Capabilities

- **CAP-1**
  - **intent:** The system can transition an execution into a resumable `:suspended` state when `PolicyGate` requires human approval, and resume execution automatically once approval is recorded.
  - **success:** A task requiring approval enters `:suspended` in `DAGStore` and `ApprovalQueue`; calling `POST /api/v1/approvals/:id/approve` resumes execution from the suspended node through to terminal completion without restarting earlier completed nodes.

- **CAP-2**
  - **intent:** The DAG execution engine can execute parallel branches and merge their outputs without key collisions, context overwrites, or artifact data loss.
  - **success:** Two concurrent sibling nodes producing distinct outputs and artifacts merge into `context.node_outputs[node_id]` with all generated `:artifacts` and history events preserved in concatenation.

- **CAP-3**
  - **intent:** The system can serialize execution context to JSON and restore it on resumption with schema-defined control keys correctly atomized.
  - **success:** Restoring an execution context from DB storage preserves atom keys for engine control attributes, ensuring Elixir pattern matches on `:artifacts`, `:status`, and `:node_outputs` succeed without key-type errors.

- **CAP-4**
  - **intent:** The tool registry can monitor internal and external MCP tool availability and mark repeatedly failing tools unavailable before LLM dispatch.
  - **success:** Three consecutive execution or connection failures to an external tool trip its circuit breaker to `unavailable` status, preventing subsequent LLM tool calls from stalling and logging an alert on the dashboard.

- **CAP-5**
  - **intent:** The security layer can enforce capability-based scopes (`file_read`, `file_write`, `shell_exec`, `web_fetch`) and restricted path/domain boundaries for tool execution.
  - **success:** A tool call attempting to write outside declared safe directory paths or fetch from unauthorized network domains is rejected by `PolicyGate` with a structured `policy.blocked` trace event.

- **CAP-6**
  - **intent:** The runtime watchdog can detect stalled executions exceeding configured timeouts and transition them cleanly to a terminal state.
  - **success:** An execution exceeding its configured SLA timeout without progress is transitioned to `timed_out` by the watchdog supervisor, unlocking associated locks and notifying the timeline.

- **CAP-7**
  - **intent:** The LiveView agent dashboard can list, search, filter, and replay historical executions and their complete event timelines.
  - **success:** Operators can filter past executions on `/agent` by status (`succeeded`, `failed`, `suspended`), select any run, and inspect its complete chronological timeline of events, policy decisions, and tool calls.

## Constraints

- Implementation must strictly obey invariants AD-1 through AD-5 codified in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md).
- Local development must remain 100% operational on SQLite3 (`priv/repo/aos_dev.db`) without requiring Docker daemon or external databases.
- All state transitions must adhere to Elixir/OTP supervision conventions with zero global mutable state.

## Non-goals

- Multi-node distributed Erlang cluster synchronization across multiple physical hosts.
- Real-time token-by-token typewriter WebSocket streaming in LiveView (existing PubSub execution events are retained).

## Success signal

- All unit and integration tests pass via `mix test`.
- A simulated task encountering a high-risk tool call transitions to `:suspended`, triggers a visible dashboard approval request, and successfully resumes and finishes upon approval without re-running earlier nodes.
- Parallel fan-in DAG execution preserves all branch outputs with zero key collisions.
