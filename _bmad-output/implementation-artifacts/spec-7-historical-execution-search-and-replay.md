---
title: 'Story 7: Historical Execution Search and Replay on LiveView Dashboard'
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

**Problem:** Operators cannot search, filter, or inspect past executions from the LiveView web dashboard without manually querying the database. Previous runs and their timelines (events, policy decisions, tool calls) are inaccessible once the active session changes.

**Approach:** Add an `Executions` tab to the `/agent` dashboard right pane. Operators can list historical executions, filter them by status (`all`, `succeeded`, `failed`, `suspended`, `timed_out`, `running`), and search by task keyword. Clicking any execution transitions directly to the `Timeline` tab, loading and displaying the complete chronological audit of engine events, policy gate decisions, and tool executions.

## Boundaries & Constraints

**Always:**
- Obey AD-4 and Monitoring & Observability conventions in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md).
- Support filtering by execution status: `all`, `succeeded`, `failed`, `suspended`, `timed_out`, `running`.
- Support substring search over task text.
- Retain complete chronological event ordering when inspecting execution timelines.
- Maintain responsive, non-blocking LiveView updates.

**Never:**
- Never crash LiveView on empty search results or nonexistent execution IDs.
- Never wipe active in-flight chat state when switching between tabs or inspecting past runs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| View Executions Tab | Click `switch_right_tab` with `tab="executions"` | Displays search form and list of past executions with status badges and timestamps | Empty state if none found |
| Filter by Status | Select `status="succeeded"` | Refreshes list showing only executions with `status == "succeeded"` | Clean reactive filter |
| Filter by Search Query | Input `query="analysis"` | Refreshes list showing executions matching `"analysis"` in `task` | Case-insensitive substring match |
| Select Execution | Click `select_execution` with `id="exec-123"` | Sets `current_execution_id`, switches to `:timeline`, loads chronological events | Graceful fallback if no events |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/execution/store.ex` -- Add `status` and `query` filter support to `list_executions/1`.
- `lib/aos/agent_os/dashboard_service.ex` -- Add `load_historical_executions/2` and `select_execution/2`.
- `lib/aos_web/live/agent_dashboard_live.ex` -- Add `switch_right_tab("executions")`, `filter_executions`, and `select_execution` handlers.
- `lib/aos_web/live/agent_dashboard_live.html.heex` -- Render Executions tab header, filter controls, execution list cards, and timeline links.
- `test/aos_web/live/agent_dashboard_live_test.exs` -- Add LiveView tests for execution listing, filtering by status/query, and timeline inspection.

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/execution/store.ex` -- Implement status and keyword query filters in `list_executions/1`.
- [x] `lib/aos/agent_os/dashboard_service.ex` -- Add historical execution loading and selection helpers.
- [x] `lib/aos_web/live/agent_dashboard_live.ex` & `.heex` -- Implement Executions tab with reactive filter and timeline link.
- [x] `test/aos_web/live/agent_dashboard_live_test.exs` -- Verify execution search, filtering, and timeline inspection.
