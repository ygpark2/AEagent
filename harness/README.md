# Agent harness contract

`manifest.json` is the repository-level default contract. A task can overlay
the contract through `initial_context[:harness]` or pass a complete
`harness_manifest` option. The persisted episode keeps the resolved manifest,
budgets, verification report, failure attribution, intervention count, and
ordered trace events together.

## Episode package

Each execution has at most one `agent_harness_episodes` row. Its trace stream
is stored in `agent_harness_traces` and uses these normalized event classes:

- `task`: task specification and resolved contract
- `lifecycle`: queued/running/finished
- `node`, `tool`, `artifact`, `orchestration`: runtime progress
- `verification`: deterministic test/lint/build gate results
- `failure`: categorized failure evidence
- `intervention`: approval or human intervention records

Trace writes accept an idempotency key, so retries and resumed orchestration
can safely re-emit the same event. `GET /api/v1/executions/:id` and replay
payloads expose the episode package.

## Verification and hygiene

Set `verification.profile` to `elixir` to require formatting, compilation,
and tests before an execution is marked successful. The allowlisted command
runner records exit code, output, timeout, and duration for every command.

`golden_principles.json` defines repository invariants. The memory cleanup
cycle audits them periodically, and `AOS.AgentOS.Operations.doctor/0` exposes
the latest on-demand report.
