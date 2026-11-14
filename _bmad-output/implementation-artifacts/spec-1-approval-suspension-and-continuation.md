---
title: 'Story 1: Implement resumable approval suspension state in DAGEngine and ApprovalQueue'
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

**Problem:** When `PolicyGate` requires human approval (`{:approval_required, request}`), `DAGEngine` terminates the execution into an unrecoverable `blocked` state. Approval events in `ApprovalQueue` do not wake up the suspended DAG run, making human-in-the-loop workflows dead ends.

**Approach:** Introduce a first-class `:suspended` state in `DAGEngine` and `Executions` when approval is required, persisting the exact node checkpoint. Wire `ApprovalQueue.approve/2` and `ApprovalController.approve/2` to automatically resume the suspended DAG run from the interrupted node.

## Boundaries & Constraints

**Always:**
- Obey AD-3 and AD-4 from [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md): approval-gated runs must suspend gracefully rather than abort, preserving the node state.
- Resumption must continue from the suspended node with the approved request stored in context, without re-executing previously succeeded nodes.
- Maintain full backward compatibility for non-approval blocking reasons (`:out_of_budget`, `:dangerous_intent`, etc.), which remain terminal `:blocked`.

**Never:**
- Never restart the entire DAG or re-run completed predecessor nodes upon approval.
- Never bypass `PolicyGate` on subsequent nodes during resumed execution.
- Never discard intermediate `:artifacts` or accumulated context when transitioning into `:suspended`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| PolicyGate triggers approval | Tool execution requiring confirmation in DAG node | DAGRun and Execution transition to `"suspended"`; approval request recorded in `ApprovalQueue` | Status persisted; process yields cleanly |
| User approves via API/Dashboard | `POST /api/v1/approvals/:id/approve` | Approval marked `"approved"`; `DAGEngine.resume/2` called; blocked node re-evaluates with approval and succeeds | If DAG run not found, return `{:error, :dag_run_not_found}` |
| User rejects approval | `POST /api/v1/approvals/:id/reject` | Approval marked `"rejected"`; DAGRun transitions to `"cancelled"` or `"failed"` with rejection reason | Execution marked terminal; timeline records rejection |
| Redundant approval call | Approval already in `"approved"` or `"rejected"` state | Rejects duplicate call with error tuple | Returns `{:error, "approval request already decided"}` |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/core/policy_gate.ex` -- Policy check entry point emitting `{:approval_required, request}`
- `lib/aos/agent_os/orchestration/dag_engine.ex` -- DAG lifecycle manager; needs `finish_suspended/5` and resumption hook
- `lib/aos/agent_os/orchestration/dag_store.ex` -- DAG persistence layer; support `"suspended"` status query and updates
- `lib/aos/agent_os/executions.ex` -- Execution coordinator; add `"suspended"` to `allowed_statuses` in `resume_execution/2`
- `lib/aos/agent_os/tool_use/approval_queue.ex` -- Approval request queue; emit resume trigger upon `approve/2`
- `lib/aos_web/controllers/v1/approval_controller.ex` -- Web API controller handling approval decisions
- `test/aos/agent_os/orchestration/dag_engine_test.exs` -- Verification suite for DAG suspension and resumption

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/core/dag_run.ex` & `lib/aos/agent_os/orchestration/dag_store.ex` -- Allow `"suspended"` status in DAGRun schemas and queries.
- [x] `lib/aos/agent_os/orchestration/dag_engine.ex` -- Implement `finish_suspended/5` when reason matches `{:approval_required, _}`; update `DAGEngine.resume/2` to inject approval decision context and execute remaining nodes.
- [x] `lib/aos/agent_os/executions.ex` -- Update `resume_execution/2` to accept `"suspended"` status and invoke `DAGEngine.resume/2` when engine is `"dag"`.
- [x] `lib/aos/agent_os/tool_use/approval_queue.ex` -- Wire `approve/2` to trigger execution resumption with execution and DAG run references.
- [x] `test/aos/agent_os/orchestration/dag_engine_test.exs` -- Add unit and integration tests verifying suspension on approval request and seamless continuation upon approval.

**Acceptance Criteria:**
- Given a DAG task executing a node that requires human approval, when `PolicyGate` halts with `{:approval_required, req}`, then the DAGRun and Execution statuses become `"suspended"` with all prior node outputs intact in `DAGStore`.
- Given a suspended DAG execution, when the user calls `ApprovalQueue.approve(req_id)` or `POST /api/v1/approvals/:id/approve`, then the suspended node re-executes successfully and the DAG completes to `"succeeded"` without restarting prior nodes.

## Implementation Notes

- Added `"suspended"` status to `DAGRun`, `DAGNode`, `Execution`, `Session`, and `StateMachine`.
- Implemented `finish_suspended/5` in `DAGEngine` preserving accumulated node context, artifacts, and ensuring approval request in `ApprovalQueue`.
- Updated `DAGEngine.resume/2` to resolve and inject approval decision context into resumed execution and execute remaining nodes without re-running succeeded nodes.
- Reconstructed predecessor node contexts from `DAGStore` outputs on resumption so inputs and artifacts are retained.
- Updated `EventProtocol` to recognize `orchestration.suspended` and `node.suspended` event types.
- Updated `ApprovalQueue.approve/2` to trigger execution resumption for suspended executions unless suppressed.
- Updated `ApprovalQueue.reject/2` to mark suspended DAG runs `cancelled` and executions terminal `failed`.
- Updated `ApprovalQueue.decide/3` to return `{:error, "approval request already decided"}` on duplicate decisions.
- Added comprehensive unit and integration tests in `dag_engine_test.exs` and `approval_controller_test.exs`.

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence / Action |
| --- | --- | --- | --- |
| `ApprovalQueue.fail_suspended_execution` passes empty context wiping task and domain | high | patch | Pass existing execution attributes in context to preserve task and domain; support both suspended and blocked statuses |
| `AgentDashboardLive` triggers double resume with `ApprovalQueue.approve` auto-resume | high | patch | Add concurrency guard in `DAGEngine.resume/2` and pass `resume: false` in `AgentDashboardLive` |
| `suspend_execution/3` triggers `Harness.record_failure` and terminal notification | high | patch | Do not call `Harness.record_failure` or `notify_terminal_event` for non-terminal suspension |
| `Execution` schema `@statuses` missing `"cancelled"` | medium | patch | Add `"cancelled"` to `AOS.AgentOS.Core.Execution` `@statuses` |
| `orchestrate/8` calls `mark_running/1` on every recursive loop | medium | patch | Call `mark_running/1` once on entry/resumption, not inside every recursive iteration |
| `DAGEngine.resume/2` lacks concurrency guard for running runs | medium | patch | Check `run.status in ~w(queued running)` and return `{:error, {:dag_already_running, ...}}` |
| `initial_resumed_contexts` and `restore_context` drop custom node data on resume | medium | patch | Preserve node outputs and custom keys across resumption |
