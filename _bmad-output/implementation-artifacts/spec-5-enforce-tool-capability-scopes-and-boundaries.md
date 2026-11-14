---
title: 'Story 5: Enforce tool capability scopes and filesystem/network boundaries'
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

**Problem:** Tool execution currently lacks fine-grained capability scope verification (`file_read`, `file_write`, `shell_exec`, `web_search`, `web_fetch`) and perimeter boundaries (restricting filesystem paths to workspace/safe paths and outgoing network requests to approved domains), risking unauthorized filesystem writes or external domain egress.

**Approach:** Implement `PolicyGate.check_tool/5` and capability mapping in `Permissions`. Verify tool capability scopes against context `allowed_scopes`, ensure file operations remain within `safe_paths` or `workspace_root` (preventing directory traversal and sibling path spoofing), and enforce that network calls (`fetch_url`, `web_search`) only target `allowed_domains` if configured. Emit structured `policy.blocked` trace events with specific blocking reasons on any violation.

## Boundaries & Constraints

**Always:**
- Obey AD-4 and Policy & Governance invariants in [ARCHITECTURE-SPINE.md](file:///Users/ygpark2/pjt/projects/aeagent/_bmad-output/planning-artifacts/architecture/architecture-aeagent-2026-11-14/ARCHITECTURE-SPINE.md).
- Block any attempt to write or read outside declared `safe_paths` (defaulting to `workspace_root`) with `:unsafe_file_path`.
- Block any tool call attempting to access network domains not listed in configured `allowed_domains` with `:unauthorized_domain`.
- Block any tool requiring a scope not listed in configured `allowed_scopes` with `:scope_not_allowed`.
- Emit `policy.blocked` trace event to `EventStore` via `PolicyTrace` on any rejection.
- Add `:unsafe_file_path`, `:unauthorized_domain`, and `:scope_not_allowed` to `PolicyGate.blocking_reason?/1`.

**Never:**
- Never bypass path canonicalization (`Path.expand/2`), which protects against relative traversal (`../`).
- Never allow sibling paths that merely share the workspace root prefix string (e.g. `workspace <> "_sibling"`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Allowed Scope | Tool scope in `context.allowed_scopes` | Returns `:ok`; records `policy.allowed` trace event | Execution proceeds |
| Disallowed Scope | Tool scope not in `context.allowed_scopes` | Returns `{:error, :scope_not_allowed}`; records `policy.blocked` trace | Halts tool dispatch |
| Safe File Path | Path inside `workspace_root` or `safe_paths` | Returns `:ok`; records `policy.allowed` trace event | Tool execution proceeds |
| Path Traversal Escape | Path containing `../../etc/passwd` or outside safe paths | Returns `{:error, :unsafe_file_path}`; records `policy.blocked` trace | Blocks execution |
| Sibling Path Prefix Spoof | Path in `workspace <> "_sibling/out.txt"` | Returns `{:error, :unsafe_file_path}`; records `policy.blocked` trace | Blocks execution |
| Authorized Domain | Domain matches `allowed_domains` (exact or subdomain) | Returns `:ok`; records `policy.allowed` trace event | Network request proceeds |
| Unauthorized Domain | Domain not matching `allowed_domains` list | Returns `{:error, :unauthorized_domain}`; records `policy.blocked` trace | Blocks request |

</frozen-after-approval>

## Code Map

- `lib/aos/agent_os/tools/permissions.ex` -- Add `tool_scope/1` helper to map tool names to capability scopes.
- `lib/aos/agent_os/core/policy_gate.ex` -- Implement `check_tool/5` and extend `blocking_reason?/1`.
- `lib/aos/agent_os/roles/executor.ex` -- Wire `PolicyGate.check_tool/5` before tool execution.
- `lib/aos/agent_os/roles/llm.ex` -- Wire `PolicyGate.check_tool/5` before tool dispatch.
- `test/aos/agent_os/core/policy_gate_test.exs` -- Add comprehensive tests for tool scope, path boundaries, and domain allowlists.

## Tasks & Acceptance

**Execution:**
- [x] `lib/aos/agent_os/tools/permissions.ex` -- Add `tool_scope/1` mapping tool name to capability scope.
- [x] `lib/aos/agent_os/core/policy_gate.ex` -- Add `check_tool/5` and update `blocking_reason?/1`.
- [x] `lib/aos/agent_os/roles/executor.ex` & `llm.ex` -- Integrate `PolicyGate.check_tool/5`.
- [x] `test/aos/agent_os/core/policy_gate_test.exs` -- Verify scope checks, filesystem boundaries, and domain allowlists.
