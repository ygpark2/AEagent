---
title: 'Story 2: Implement namespaced parallel fan-in merging in DAGEngine'
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

**Problem:** In `DAGEngine`, when parallel sibling nodes complete and join into a fan-in successor node or final context, contexts are merged using naive `Map.merge/2`. This destructively overwrites `:artifacts`, sibling `:result` values, and intermediate data produced by earlier parallel branches.

**Approach:** Implement deep namespaced fan-in merging. Individual node outcomes are preserved under `context.node_outputs[node_id]`, while shared list accumulators (such as `:artifacts` and trace lists) are concatenated cleanly without data loss.

## Boundaries & Constraints

**Always:**
- Obey AD-2 from [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md): parallel fan-in must namespace outputs by node ID and append shared accumulator lists.
- Preserve backward compatibility for single-predecessor linear DAGs where `context[:result]` and `context[:artifacts]` work as expected.
- Ensure all artifacts emitted across parallel branches are retained in the merged context `:artifacts` list.

**Never:**
- Never let one parallel branch's `:artifacts` overwrite or discard another branch's `:artifacts`.
- Never mutate or drop predecessor outputs when more than two branches converge.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Parallel Fan-In (2 nodes) | Node A produces artifact A1, Node B produces artifact B1 | Fan-in node receives `context.node_outputs` containing A and B, and `:artifacts` containing `[A1, B1]` | No collision; both artifacts preserved |
| Multi-branch result clash | Node A produces `result: "res_a"`, Node B produces `result: "res_b"` | `context.node_outputs["a"][:result] == "res_a"` and `context.node_outputs["b"][:result] == "res_b"`; `context[:inputs]` contains both | Downstream node accesses inputs via node name |
| Empty predecessor output | One branch produces nil or empty output | Merged context preserves existing outputs without crashing on nil | Safely skips empty branch |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/orchestration/dag_engine.ex` -- Core fan-in merge logic in `node_context/6`, `final_context/3`, and predecessor context merging
- `test/aos/agent_os/orchestration/dag_engine_test.exs` -- Test suite to add concurrent fan-in assertions verifying artifact retention and namespacing

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/orchestration/dag_engine.ex` -- Implement namespaced merging helper for predecessor contexts: retain `node_outputs[node_id]`, concatenate `:artifacts`, and prevent key overwriting.
- [x] `lib/aos/agent_os/orchestration/dag_engine.ex` -- Update `final_context/3` to concatenate all branch `:artifacts` and preserve `node_outputs`.
- [x] `test/aos/agent_os/orchestration/dag_engine_test.exs` -- Add unit test for parallel diamond DAG (A -> B, C -> D) verifying D receives both B and C outputs and all artifacts from B and C.

**Acceptance Criteria:**
- Given a DAG with two parallel branches B and C converging on node D, when B produces artifact `art_b` and C produces artifact `art_c`, then node D receives `artifacts: [art_b, art_c]` and `node_outputs: %{"b" => ..., "c" => ...}` without data loss.

## Implementation Notes

## Spec Change Log

## Review Triage Log
