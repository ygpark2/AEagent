defmodule AOS.AgentOS.Core.ToolAudit do
  @moduledoc """
  Persistent audit log for each tool invocation.
  """
  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(succeeded failed rejected pending)
  @risk_tiers ~w(low medium high)
  @approval_statuses ~w(not_required approved rejected)

  schema "agent_tool_audits" do
    field :execution_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :server_id, :string
    field :tool_name, :string
    field :risk_tier, :string
    field :status, :string
    field :approval_required, :boolean, default: false
    field :approval_status, :string, default: "not_required"
    field :arguments, :map, default: %{}
    field :normalized_result, :map, default: %{}
    field :error_message, :string
    field :attempts, :integer, default: 1
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(tool_audit, attrs) do
    tool_audit
    |> cast(attrs, [
      :execution_id,
      :session_id,
      :server_id,
      :tool_name,
      :risk_tier,
      :status,
      :approval_required,
      :approval_status,
      :arguments,
      :normalized_result,
      :error_message,
      :attempts,
      :started_at,
      :finished_at
    ])
    |> validate_required([
      :server_id,
      :tool_name,
      :risk_tier,
      :status,
      :approval_required,
      :approval_status,
      :arguments,
      :normalized_result,
      :attempts,
      :started_at,
      :finished_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:risk_tier, @risk_tiers)
    |> validate_inclusion(:approval_status, @approval_statuses)
  end
end
