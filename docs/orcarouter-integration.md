# OrcaRouter Integration

Branch: `feat/orcarouter-provider`

## Implementation

- Reuses the OpenAI-compatible provider; defaults remain unchanged.
- Accepts root, `/v1`, and legacy `/v1beta` base URLs with optional trailing slashes.
- Uses Bearer authentication and preserves provider-qualified model IDs.
- Disables Req automatic retry and redirect for LLM calls. The LLM client owns retries.
- Keeps HTTP status, error code/type and Retry-After without logging raw error bodies.
- Honors Retry-After up to 60 seconds; longer delays return the error to the caller.
- Retries free-tier `free_rate_limited` only once and only with Retry-After.
- Treats unavailable BYOK keys and unavailable models as terminal failures.
- Adds opt-in SSE text and tool-call assembly with final usage, EOF detection and in-band error handling.
- A per-call `on_delta` callback can return `:halt` to cancel when a text delta arrives.
- Partial-stream failures are terminal; completed tool calls use existing approval and budget controls.
- Dashboard previews are temporary and scoped by request reference; final workflow messages remain authoritative.
- `AGENT_STREAM` defaults to false. Local/Fake providers retain non-streaming behavior.
- No provider-specific fallback chain or automatic paid-model fallback is enabled.

## Verification

Local validation on 2026-09-05:

- `mix test`: 254 tests, 0 failures, 3 external tests excluded (251 executed).
- Changed Elixir files pass `mix format --check-formatted`; `git diff --check` passes.
- `mix credo --strict`: still exits with existing findings in other files (2 warnings, 21 refactoring opportunities, 13 readability issues, 6 design suggestions). No findings remain in the integration files.
- Fixed the existing Autonomy test's missing SQL sandbox ownership by using `AOS.DataCase`, so approval-policy regression tests run correctly.
- Local tests exercise byte-split UTF-8 SSE, interleaved tool arguments, partial failure, callback cancellation, the role tool loop, dashboard previews, endpoint variants and retry policy.

Live validation attempt on 2026-09-05:

- Selected model: `orcarouter/auto`; model listing passed.
- Two generation attempts were both rejected with HTTP 402, code `insufficient_user_quota`, type `insufficient_quota`. The terminal error policy prevented retries.
- Result: 3 live tests, 1 passed and 2 failed. Neither test reached its streaming phase. No successful generation or usage report was returned; actual billing has not been independently checked.
- Remaining generation checks are blocked until account balance/key quota is available. No top-up or account settings were changed.

```sh
mix test test/aos/agent_os/llm test/aos/http_client_stream_test.exs test/aos_web/live/agent_dashboard_live_test.exs
mix test
mix credo --strict
```

Credentials, model selection and a test budget have been supplied privately. Live generation verification is blocked by provider quota. Do not commit keys or raw transcripts. Use a key with an account-side spending limit. Confirm the selected model supports tools.

The executable live smoke suite is excluded from normal tests. Set `ORCAROUTER_API_KEY` and `ORCAROUTER_MODEL` in the invoking environment or the ignored `.env-test` file, then run:

```sh
mix test test/aos/agent_os/llm/orcarouter_live_test.exs --include external --trace
```

It makes one model-list request and up to eight generation requests, with no client retries. Prompts request short output but do not enforce a token or dollar cap; use an account-side key spending limit. It tests Korean conversation history and a synthetic echo-tool round trip with streaming off and on. It never dispatches model-selected real tools. Output contains only check names, streaming mode, returned model IDs and token totals. Approval controls and actual Agent tool execution remain covered by local tests and the live workflow checklist below.

- [x] Model listing includes the selected model (`orcarouter/auto`).
- [ ] Single-turn and multi-turn Korean Chat succeeds.
- [ ] Streaming produces text deltas and a final response with usage.
- [ ] A read-only tool runs once and its result reaches the final answer, with Streaming off and on.
- [ ] A tool requiring approval still waits for approval.
- [ ] Authentication and unavailable-model errors are terminal.
- [ ] Compare tokens, latency and dashboard billing for the test requests.
- [ ] Record tested model IDs, date, result and total cost here without secrets.

Inject 429, 5xx, malformed JSON, truncated SSE and partial tool arguments locally instead of exhausting live quota.

## Built With Submission Draft

Submission URL: https://www.orcarouter.ai/built-with

Project name: AEagent (Autonomous Evolutionary Agent)

Repository: https://github.com/ygpark2/AEagent

Description:

AEagent is an Elixir/OTP and Phoenix LiveView application that runs outcome-driven agent workflows. It combines graph-based execution, MCP tools, human approval, budget policies and execution observability. OrcaRouter is being integrated as an optional OpenAI-compatible provider, allowing users to supply their own API key and model ID while retaining existing workflow and approval controls.

Integration status: Implemented on an integration branch; live provider verification and release pending.

Requested listing: Built with OrcaRouter, with referral and partner dashboard information after approval.

Contact details have been supplied privately and are intentionally omitted from this public document. The official Apply with GitHub flow leads to `https://www.orcarouter.ai/console/partner-apply?intent=oss` after website login. It requires a GitHub-linked OrcaRouter session and repository ownership verification; a generation API key and `gh` login do not establish that website session. This draft has not been submitted. Use category `selfhost` and the repository URL above as the project URL. Do not claim partner status before approval.

GitHub draft PR text is prepared in `docs/orcarouter-pr.md`. CLI authentication is verified; the earlier sandbox-only authentication failure did not reflect the actual keychain login.

## Release Gates

- [ ] Local tests and static checks pass; record any pre-existing failures.
- [ ] Live verification checklist passes.
- [ ] Built with application submitted and approval confirmed.
- [ ] Referral URL and Partner Dashboard access verified; add and label the real referral URL in signup guidance.
- [ ] Review and merge integration changes, then release through the repository deployment workflow.

Rollback: restore previous `AGENT_BASE_URL`, `AGENT_API_KEY`, `AGENT_MODEL` and `CLIPROXYAPI` values, disable `AGENT_STREAM`, and restart/rebuild as appropriate. No database migration is required.

## References

- https://docs.orcarouter.ai/introduction
- https://docs.orcarouter.ai/advanced/streaming
- https://docs.orcarouter.ai/advanced/tool-calling
- https://docs.orcarouter.ai/operations/errors
- https://docs.orcarouter.ai/getting-started/models
