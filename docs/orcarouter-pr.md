# Add optional OrcaRouter support and streamed agent responses

AEagent's compatible provider currently appends `/v1` to every base URL, making OrcaRouter's documented URL produce `/v1/v1/chat/completions`. This change normalizes API endpoints and supports OrcaRouter using the existing provider configuration, without changing defaults.

Opt-in streaming assembles SSE text and tool-call deltas before passing completed calls through the existing agent tool loop. The dashboard displays temporary response previews. Partial-stream errors are terminal, and HTTP retries respect OrcaRouter error codes and Retry-After. Req decoding, redirect and retry options are explicit for LLM calls.

README and environment examples document setup and rollback. The existing Autonomy tests now use the SQL sandbox to exercise approval policies successfully.

Validation:

- Local suite: 254 tests, 0 failures, 3 external tests excluded (251 executed).
- Format and whitespace checks passed.
- Credo reports existing findings outside the integration files; no integration-file findings remain.
- Live tests are separately tagged `external`, require locally supplied OrcaRouter credentials/model, and are excluded from normal runs.
- Live `orcarouter/auto` model-list check passed. Two generation attempts were rejected with HTTP 402 `insufficient_user_quota` (`insufficient_quota`); no retries were made. Chat, streaming and tool compatibility remain unverified against the live service until quota is available.
- Re-checked 2026-09-19: paid path still HTTP 402 `insufficient_user_quota`; a development/testing credit grant offered by OrcaRouter had not yet been applied. Free-tier fallback models were also attempted and rejected (`err_free_access_denied` — workspace's linked GitHub account does not meet the required account age), an eligibility gate rather than a transient rate limit.

Draft status: live generation validation is blocked by provider quota. OrcaRouter has confirmed (2026-09-19) that Built With submission may proceed ahead of completed live verification, against the integration branch as-is, with no requirement to set OrcaRouter as the default provider; referral URL and Partner Dashboard access follow after registration. Submission itself still requires a GitHub-linked OrcaRouter website session, separate from CLI authentication, and has not yet been completed. Do not merge or release until the integration checklist is complete. No referral URL or partner endorsement is claimed.
