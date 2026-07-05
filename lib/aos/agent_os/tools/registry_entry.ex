defmodule AOS.AgentOS.Tools.RegistryEntry do
  @moduledoc """
  Persistent capability and policy metadata for an MCP tool.
  """
  use AOS.Schema
  import Ecto.Changeset

  @risk_tiers ~w(low medium high)
  @health_statuses ~w(unknown healthy degraded unavailable)

  schema "agent_tool_registry" do
    field :server_id, :string
    field :tool_name, :string
    field :description, :string
    field :input_schema, :map, default: %{}
    field :risk_tier, :string, default: "medium"
    field :requires_confirmation, :boolean, default: false
    field :retryable, :boolean, default: false
    field :timeout_ms, :integer, default: 60_000
    field :enabled, :boolean, default: true
    field :health_status, :string, default: "unknown"
    field :last_seen_at, :utc_datetime_usec
    field :last_health_check_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :server_id,
      :tool_name,
      :description,
      :input_schema,
      :risk_tier,
      :requires_confirmation,
      :retryable,
      :timeout_ms,
      :enabled,
      :health_status,
      :last_seen_at,
      :last_health_check_at,
      :metadata
    ])
    |> validate_required([
      :server_id,
      :tool_name,
      :input_schema,
      :risk_tier,
      :requires_confirmation,
      :retryable,
      :timeout_ms,
      :enabled,
      :health_status,
      :metadata
    ])
    |> validate_inclusion(:risk_tier, @risk_tiers)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> unique_constraint([:server_id, :tool_name],
      name: :agent_tool_registry_server_id_tool_name_index
    )
  end
end
