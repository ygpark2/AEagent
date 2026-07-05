defmodule AOS.Repo.Migrations.CreateAgentToolRegistry do
  use Ecto.Migration

  def change do
    create table(:agent_tool_registry, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :server_id, :string, null: false
      add :tool_name, :string, null: false
      add :description, :text
      add :input_schema, :map, null: false, default: %{}
      add :risk_tier, :string, null: false, default: "medium"
      add :requires_confirmation, :boolean, null: false, default: false
      add :retryable, :boolean, null: false, default: false
      add :timeout_ms, :integer, null: false, default: 60_000
      add :enabled, :boolean, null: false, default: true
      add :health_status, :string, null: false, default: "unknown"
      add :last_seen_at, :utc_datetime_usec
      add :last_health_check_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:agent_tool_registry, [:server_id, :tool_name])
    create index(:agent_tool_registry, [:enabled])
    create index(:agent_tool_registry, [:health_status])
    create index(:agent_tool_registry, [:risk_tier])
  end
end
