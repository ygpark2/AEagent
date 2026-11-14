<!-- bmad:context -->
<!-- Verified 2026-11-14 against a726da7. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## aeagent

Autonomous Evolutionary Agent (AOS) framework built on Elixir/OTP. Outcome-driven agent graph with a 4-tier cognitive architecture (Brain, Hands, Eyes, Nerve), local RAG via Nx/Bumblebee, and Phoenix LiveView monitoring. Planning and project documentation live in `docs/` and `README.md`.

## Policy

- Direct commits to `main` are permitted.
- Never edit `.env` or commit secrets; configure environment variables using `.env-sample` as the template.
- Never modify deployment files (`deploy/`, `Dockerfile*`) or CI workflows (`.ci/`, `.github/workflows/`) without explicit instruction.
- Never hand-edit SQLite database files (`priv/repo/*.db`) or `.codex/` directory.

## Where things are

- Agent graph & cognitive nodes: `lib/aos/agent_os/` (`core/`, `orchestration/`, `roles/`, `skills/`, `tools/`)
- Supervision tree & runtime setup: `lib/aos/application.ex`, `lib/aos/runtime/`
- Web API & LiveView dashboard: `lib/aos_web/`
- Database schema & migrations: `lib/aos/repo.ex`, `priv/repo/`
- External integration docs: `docs/orcarouter-integration.md`

## Running and verifying

- Requires Elixir `~> 1.18.0` and Erlang `27.0` (as defined in `.tool-versions`).
- Run code formatting check: `mix format --check-formatted`
- Run static analysis: `mix credo --strict`
- Run single test files while iterating: `mix test test/path/to/test_file.exs` (the full test suite resets the database via `ecto.reset`).
- Interactive agent REPL: `make local-iex` or `make local-chat`

## Conventions that differ from defaults

- Architecture strictly follows 4 cognitive tiers: L1 Brain (`thinker`), L2 Hands (`executor`), L3 Eyes (`critic`), L4 Nerve (`router`, `reporter`). Place new agent behaviors in their corresponding layer under `lib/aos/agent_os/`.
- Local dev uses SQLite3 (`DATABASE_PATH=priv/repo/aos_dev.db`), while CI/prod uses PostgreSQL.

<!-- /bmad:context -->
