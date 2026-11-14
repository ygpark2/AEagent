---
title: 'Story 4: Add MCP tool health monitoring and automatic circuit breaker'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_commit: 'a726da7'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/specs/spec-runtime-resilience-and-governance/SPEC.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** When external MCP servers or tools fail repeatedly or become unreachable, LLM dispatch attempts continue to invoke them, leading to repeated timeouts, wasted tokens, and stalled executions without circuit breaking or operator visibility.

**Approach:** Implement health monitoring and an automatic circuit breaker in `AOS.AgentOS.Tools.Registry`. Track consecutive execution and connection failures, automatically transition repeatedly failing tools (threshold: 3 consecutive failures) to `"unavailable"`, emit a timeline alert event, and prevent LLM dispatch to unavailable tools. Add `GET /api/v1/tools/registry/health` to expose health status.

## Boundaries & Constraints

**Always:**
- Obey AD-4 and Consistency Conventions in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md).
- Automatic trip threshold: 3 consecutive failures transitions tool to `"unavailable"`.
- A single successful execution or explicit operator update resets consecutive failure count and restores health to `"healthy"`.
- Emitting circuit breaker events (`tool.circuit_breaker.tripped`) to `EventStore` so operators and dashboard can observe the state transition.

**Never:**
- Never crash the node execution when recording health or tripping the breaker.
- Never permanently block tools without allowing operator manual reset or automatic recovery on next successful ping.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Single Tool Failure | Tool execution returns `{:error, reason}` | `consecutive_failures` increments to 1; status remains `"healthy"` | Recorded in metadata; error returned normally |
| Consecutive 3 Failures | 3rd consecutive tool error | `consecutive_failures` reaches 3; `health_status` transitions to `"unavailable"`; `tool.circuit_breaker.tripped` emitted | Tool is marked unavailable; future checks return false |
| Tool Success after Failure | Tool execution succeeds | `consecutive_failures` resets to 0; `health_status` transitions to `"healthy"` | Normal execution continues |
| Dispatch to Unavailable Tool | Tool has `health_status == "unavailable"` | `tool_available?/2` returns `false`; dispatch halts with `{:error, :tool_unavailable}` before calling LLM/MCP | Prevents wasted external network call |
| Health API endpoint | `GET /api/v1/tools/registry/health` | Returns summary counts: `{healthy: N, unavailable: M, degraded: K}` and tool list | 200 OK JSON response |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/tools/registry.ex` -- Add `record_tool_result/3`, `tool_available?/2`, `health_summary/0`
- `lib/aos/agent_os/tools.ex` -- Delegate `record_tool_result/3`, `tool_available?/2`, `registry_health_summary/0`
- `lib/aos/agent_os/roles/executor.ex` -- Invoke `record_tool_result/3` on execution success/error and check `tool_available?/2`
- `lib/aos_web/controllers/v1/tool_registry_controller.ex` & `router.ex` -- Add `GET /api/v1/tools/registry/health`
- `test/aos/agent_os/tools/registry_test.exs` -- Test circuit breaker trip, reset, and health endpoint

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/tools/registry.ex` -- Implement consecutive failure tracking, circuit breaker trip at threshold 3, and health summary.
- [x] `lib/aos/agent_os/roles/executor.ex` -- Check `tool_available?/2` before tool invocation and record result afterwards.
- [x] `lib/aos_web/controllers/v1/tool_registry_controller.ex` & `router.ex` -- Expose `GET /api/v1/tools/registry/health`.
- [x] `test/aos/agent_os/tools/registry_test.exs` -- Add unit tests for failure threshold, auto-trip, auto-reset, and health endpoint.

**Acceptance Criteria:**
- Given an active MCP tool in the registry, when it encounters 3 consecutive execution errors, its status becomes `"unavailable"` and `tool_available?/2` returns `false`.
- Given an unavailable tool, when a successful execution or reset occurs, its status returns to `"healthy"`.
- Given `GET /api/v1/tools/registry/health`, the endpoint returns a breakdown of tool health statuses.

## Implementation Notes

## Spec Change Log

## Review Triage Log
