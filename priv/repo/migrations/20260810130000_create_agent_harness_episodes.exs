defmodule AOS.Repo.Migrations.CreateAgentHarnessEpisodes do
  use Ecto.Migration

  def change do
    create table(:agent_harness_episodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :execution_id,
          references(:agent_executions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :dag_run_id,
          references(:agent_dag_runs, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "queued"
      add :manifest, :map, null: false, default: %{}
      add :budget, :map, null: false, default: %{}
      add :verification, :map, null: false, default: %{}
      add :failure_attribution, :map, null: false, default: %{}
      add :summary, :map, null: false, default: %{}
      add :intervention_count, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps()
    end

    create table(:agent_harness_traces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :episode_id,
          references(:agent_harness_episodes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :execution_id,
          references(:agent_executions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trace_type, :string, null: false
      add :phase, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :sequence, :integer, null: false, default: 0
      add :source, :string, null: false, default: "harness"
      add :idempotency_key, :string

      timestamps(updated_at: false)
    end

    create unique_index(:agent_harness_episodes, [:execution_id])
    create index(:agent_harness_episodes, [:status, :inserted_at])
    create index(:agent_harness_traces, [:episode_id, :sequence])
    create index(:agent_harness_traces, [:execution_id, :trace_type])
    create unique_index(:agent_harness_traces, [:episode_id, :idempotency_key])
  end
end
