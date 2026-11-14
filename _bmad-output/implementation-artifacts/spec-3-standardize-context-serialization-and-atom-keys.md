---
title: 'Story 3: Standardize context serialization and atom key restoration on resume'
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

**Problem:** When execution contexts are persisted to SQLite/PostgreSQL JSON storage and subsequently resumed, string keys fail to match downstream Elixir pattern matches (such as `%{artifacts: ...}`, `%{node_outputs: ...}`). Additionally, `ResumeContext` struct drops fields not explicitly defined on it, discarding artifacts and custom node outputs.

**Approach:** Standardize context serialization and deserialization across `ResumeContext`, `CheckpointService`, and `DAGEngine`. Ensure schema-defined control keys are restored to atoms, and preserve all custom context fields and `:artifacts` across serialization boundaries.

## Boundaries & Constraints

**Always:**
- Obey Consistency Conventions in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md): context keys must survive JSON serialization; engine control keys must be atomized upon restoration.
- Ensure `:artifacts`, `:node_outputs`, `:inputs`, and `:execution_history` are fully preserved across `ResumeContext` and `CheckpointService`.
- Protect against atom exhaustion by only atomizing known schema keys or using safe atom conversion (`String.to_existing_atom/1`).

**Never:**
- Never call unsafe `String.to_atom/1` on arbitrary user-provided input keys.
- Never drop unmapped custom context keys during `ResumeContext` conversion.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Restore context with artifacts and node_outputs | Stored JSON map `{"artifacts": [...], "node_outputs": {...}}` | Restored map has atom keys `:artifacts` and `:node_outputs` accessible via atom pattern matching | Fallback retains original string key as well |
| Custom domain fields in context | Stored JSON map `{"my_custom_var": 123}` | Preserved in restored context without dropping | Accessible by downstream nodes |
| ResumeContext round-trip | Context containing `:artifacts`, `:node_outputs`, `:skills` | `ResumeContext.from_map` -> `to_map` retains `:artifacts` and `:node_outputs` | Nil fields cleanly omitted |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/execution/resume_context.ex` -- Add missing fields (`:artifacts`, `:node_outputs`, `:inputs`, `:execution_history`, `custom_fields`) and update `from_map`/`to_map`
- `lib/aos/agent_os/execution/checkpoint_service.ex` -- Ensure resume context merges preserve all custom payload keys
- `lib/aos/agent_os/orchestration/dag_engine.ex` -- Standardize `restore_context/1` and `persistable_context/1`
- `test/aos/agent_os/execution/checkpoint_service_test.exs` -- Verify roundtrip context persistence and atomization

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/execution/resume_context.ex` -- Expand struct with `:artifacts`, `:node_outputs`, `:inputs`, `:execution_history`, and custom key preservation.
- [x] `lib/aos/agent_os/execution/checkpoint_service.ex` -- Update `initial_context_for_run` and checkpoint builders to preserve all context keys.
- [x] `lib/aos/agent_os/orchestration/dag_engine.ex` -- Ensure `restore_context/1` deep-atomizes `:artifacts` and `:node_outputs`.
- [x] `test/aos/agent_os/execution/checkpoint_service_test.exs` -- Add test verifying that artifacts, node_outputs, and custom keys survive checkpoint round-trip.

**Acceptance Criteria:**
- Given an execution context containing `:artifacts`, `:node_outputs`, and custom domain keys, when serialized to JSON and restored via `CheckpointService` or `DAGEngine.restore_context`, then all control keys are restored as atoms and all custom keys and artifacts are preserved intact.

## Implementation Notes

## Spec Change Log

## Review Triage Log
