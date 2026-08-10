defmodule AOS.Repo.Migrations.CreateAgentDagOrchestrations do
  use Ecto.Migration

  def change do
    alter table(:agent_executions) do
      add :engine, :string, null: false, default: "graph"
    end

    create index(:agent_executions, [:engine])

    create table(:agent_dag_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :execution_id, references(:agent_executions, type: :binary_id, on_delete: :delete_all)
      add :workflow_id, references(:agent_workflows, type: :binary_id, on_delete: :nilify_all)
      add :parent_run_id, references(:agent_dag_runs, type: :binary_id, on_delete: :nilify_all)
      add :orchestrator_id, :string, null: false, default: "dag"
      add :status, :string, null: false, default: "queued"
      add :definition, :map, null: false, default: %{}
      add :base_context, :map, null: false, default: %{}
      add :retry_policy, :map, null: false, default: %{}
      add :timeout_ms, :integer
      add :cancellation_requested, :boolean, null: false, default: false
      add :idempotency_key, :string
      add :result, :map
      add :error_message, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :heartbeat_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create table(:agent_dag_nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :dag_run_id, references(:agent_dag_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :node_id, :string, null: false
      add :component_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :outcome, :string
      add :attempt, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 1
      add :timeout_ms, :integer
      add :idempotency_key, :string
      add :input, :map, null: false, default: %{}
      add :output, :map, null: false, default: %{}
      add :error_message, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create table(:agent_dag_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :dag_run_id, references(:agent_dag_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :from_node_id, :string, null: false
      add :to_node_id, :string, null: false
      add :on, :string
      add :condition, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create table(:agent_dag_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :dag_run_id, references(:agent_dag_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :execution_id, references(:agent_executions, type: :binary_id, on_delete: :delete_all)
      add :node_id, :string
      add :orchestrator_id, :string, null: false, default: "dag"
      add :event_type, :string, null: false
      add :source, :string
      add :payload, :map, null: false, default: %{}
      add :idempotency_key, :string
      add :position, :integer, null: false, default: 0

      timestamps(updated_at: false)
    end

    create unique_index(:agent_dag_runs, [:idempotency_key])
    create index(:agent_dag_runs, [:execution_id])
    create index(:agent_dag_runs, [:status, :heartbeat_at])
    create unique_index(:agent_dag_nodes, [:dag_run_id, :node_id])
    create index(:agent_dag_nodes, [:dag_run_id, :status])
    create unique_index(:agent_dag_nodes, [:idempotency_key])
    create index(:agent_dag_edges, [:dag_run_id, :to_node_id])
    create index(:agent_dag_events, [:dag_run_id, :position])
    create index(:agent_dag_events, [:event_type])
  end
end
