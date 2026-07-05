defmodule AOS.Repo.Migrations.CreateAgentWorkflowsAndApprovalRequests do
  use Ecto.Migration

  def change do
    create table(:agent_workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :trigger, :map, null: false, default: %{}
      add :graph, :map, null: false, default: %{}
      add :required_tools, {:array, :string}, null: false, default: []
      add :policy_profile, :map, null: false, default: %{}
      add :timeout_ms, :integer
      add :retry_policy, :map, null: false, default: %{}
      add :approval_policy, :map, null: false, default: %{}
      add :state_retention_policy, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    alter table(:agent_executions) do
      add :workflow_id, references(:agent_workflows, type: :binary_id, on_delete: :nilify_all)
    end

    create table(:agent_approval_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :execution_id, references(:agent_executions, type: :binary_id, on_delete: :delete_all)
      add :session_id, references(:agent_sessions, type: :binary_id, on_delete: :delete_all)
      add :workflow_id, references(:agent_workflows, type: :binary_id, on_delete: :nilify_all)
      add :server_id, :string, null: false
      add :tool_name, :string, null: false
      add :arguments, :map, null: false, default: %{}
      add :risk_tier, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_by, :string
      add :decided_by, :string
      add :decision_reason, :text
      add :expires_at, :utc_datetime_usec
      add :decided_at, :utc_datetime_usec

      timestamps()
    end

    create table(:agent_execution_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :execution_id, references(:agent_executions, type: :binary_id, on_delete: :delete_all)
      add :session_id, references(:agent_sessions, type: :binary_id, on_delete: :delete_all)
      add :workflow_id, references(:agent_workflows, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :source, :string
      add :payload, :map, null: false, default: %{}
      add :position, :integer, null: false, default: 0

      timestamps(updated_at: false)
    end

    create unique_index(:agent_workflows, [:name])
    create index(:agent_workflows, [:status])
    create index(:agent_executions, [:workflow_id])
    create index(:agent_approval_requests, [:status, :inserted_at])
    create index(:agent_approval_requests, [:execution_id, :inserted_at])
    create index(:agent_approval_requests, [:session_id, :inserted_at])
    create index(:agent_execution_events, [:execution_id, :position])
    create index(:agent_execution_events, [:session_id, :inserted_at])
    create index(:agent_execution_events, [:event_type])
  end
end
