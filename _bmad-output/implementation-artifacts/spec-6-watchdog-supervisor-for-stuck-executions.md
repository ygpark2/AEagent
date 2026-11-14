---
title: 'Story 6: Implement watchdog supervisor for stuck and timed-out executions'
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

**Problem:** When executions stall, deadlock, or exceed their allowable SLA without finishing, they remain in the `"running"` state indefinitely, holding active resources and pending approval requests without automatic remediation or operator alerting.

**Approach:** Implement `AOS.AgentOS.Execution.Watchdog` as an OTP GenServer in the supervision tree. The watchdog scans active executions in the `"running"` state against configured SLA timeouts (or execution-specific `timeout_ms`), transitions stalled executions cleanly to `"timed_out"`, logs an `execution.timed_out` event to `EventStore`, releases associated locks and pending approval requests, and terminates stalled DAG runs.

## Boundaries & Constraints

**Always:**
- Obey AD-2, AD-3, and AD-4 in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md).
- Transition timed-out executions cleanly to terminal state `"timed_out"`.
- Cancel/reject any pending approval requests held by the timed-out execution via `ApprovalQueue`.
- Append structured `execution.timed_out` event to `EventStore`.
- Provide programmatic `check_timeouts/2` for synchronous verification in tests and operator control.
- Register `AOS.AgentOS.Execution.Watchdog` in the application supervision tree.

**Never:**
- Never crash the supervisor if an individual execution cleanup fails.
- Never transition non-running executions or executions that have not exceeded their timeout threshold.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Active execution within SLA | `started_at` recent; elapsed < timeout | No state change; remains `"running"` | No-op |
| Execution exceeding SLA | `started_at` exceeds `timeout_ms` | Transitions to `"timed_out"`; emits `execution.timed_out` event | Gracefully updates DB & notifies timeline |
| Pending Approvals on Timeout | Execution has pending approval requests in `ApprovalQueue` | Requests are automatically rejected/cancelled with reason `"Execution timed out"` | Clean resource release |
| DAG Run on Timeout | Execution has associated `DAGRun` | Associated `DAGRun` transitioned to `"timed_out"` | DAGEngine state consistency |
| Manual check sweep | `Watchdog.check_timeouts(opts)` | Returns `{:ok, timed_out_executions}` synchronously | Safe execution without waiting for timer |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/core/execution.ex` -- Add `"timed_out"` to allowed statuses.
- `lib/aos/agent_os/core/dag_run.ex` -- Add `"timed_out"` to allowed statuses.
- `lib/aos/agent_os/execution/state_machine.ex` -- Add `"timed_out"` transition and terminal status.
- `lib/aos/agent_os/tool_use/approval_queue.ex` -- Add `cancel_pending_for_execution/1`.
- `lib/aos/agent_os/executions.ex` -- Implement `timeout_execution/3`.
- `lib/aos/agent_os/execution/watchdog.ex` -- Implement `AOS.AgentOS.Execution.Watchdog` GenServer.
- `lib/aos/application.ex` -- Add `Watchdog` to supervision tree.
- `test/aos/agent_os/execution/watchdog_test.exs` -- Add unit tests for SLA timeout detection, event emission, and lock release.

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/core/execution.ex` & `state_machine.ex` -- Add `"timed_out"` status.
- [x] `lib/aos/agent_os/executions.ex` -- Implement `timeout_execution/3`.
- [x] `lib/aos/agent_os/tool_use/approval_queue.ex` -- Add `cancel_pending_for_execution/1`.
- [x] `lib/aos/agent_os/execution/watchdog.ex` -- Implement `Watchdog` worker.
- [x] `lib/aos/application.ex` -- Register `Watchdog` in supervision tree.
- [x] `test/aos/agent_os/execution/watchdog_test.exs` -- Verify timeout transition, event recording, and pending approval cancellation.
