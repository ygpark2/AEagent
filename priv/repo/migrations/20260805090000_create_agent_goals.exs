defmodule AOS.Repo.Migrations.CreateAgentGoals do
  use Ecto.Migration

  def change do
    create table(:agent_goals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :objective, :text, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :goal_type, :string, null: false, default: "ongoing"
      add :trigger, :map, null: false, default: %{}
      add :success_criteria, :map, null: false, default: %{}
      add :constraints, :map, null: false, default: %{}
      add :policy_profile, :map, null: false, default: %{}
      add :retry_policy, :map, null: false, default: %{}
      add :output_config, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :autonomy_level, :string, null: false, default: "supervised"
      add :owner, :string
      add :version, :integer, null: false, default: 1
      add :next_run_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_error, :text

      timestamps()
    end

    alter table(:agent_executions) do
      add :goal_id, references(:agent_goals, type: :binary_id, on_delete: :nilify_all)
    end

    create table(:agent_goal_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :goal_id, references(:agent_goals, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :source, :string, null: false
      add :idempotency_key, :string
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "queued"
      add :processed_at, :utc_datetime_usec
      add :error_message, :text

      timestamps()
    end

    create table(:agent_goal_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :goal_id, references(:agent_goals, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_id, references(:agent_goal_events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :execution_id, references(:agent_executions, type: :binary_id, on_delete: :nilify_all)
      add :attempt, :integer, null: false, default: 1
      add :status, :string, null: false, default: "queued"
      add :verification_result, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :error_message, :text

      timestamps()
    end

    create unique_index(:agent_goals, [:name])
    create index(:agent_goals, [:status, :next_run_at])
    create index(:agent_goals, [:owner])
    create unique_index(:agent_goal_events, [:goal_id, :idempotency_key])
    create index(:agent_goal_events, [:goal_id, :inserted_at])
    create index(:agent_goal_events, [:status, :inserted_at])
    create unique_index(:agent_goal_runs, [:event_id])
    create index(:agent_goal_runs, [:goal_id, :inserted_at])
    create index(:agent_goal_runs, [:execution_id])
    create index(:agent_executions, [:goal_id])
  end
end
