defmodule AOS.AgentOS.ToolUse.ApprovalRequest do
  @moduledoc """
  Server-side approval request for tool calls that require human review.
  """
  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved rejected expired)
  @risk_tiers ~w(low medium high)

  schema "agent_approval_requests" do
    field :execution_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :workflow_id, Ecto.UUID
    field :server_id, :string
    field :tool_name, :string
    field :arguments, :map, default: %{}
    field :risk_tier, :string
    field :status, :string, default: "pending"
    field :requested_by, :string
    field :decided_by, :string
    field :decision_reason, :string
    field :expires_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :execution_id,
      :session_id,
      :workflow_id,
      :server_id,
      :tool_name,
      :arguments,
      :risk_tier,
      :status,
      :requested_by,
      :decided_by,
      :decision_reason,
      :expires_at,
      :decided_at
    ])
    |> validate_required([:server_id, :tool_name, :arguments, :risk_tier, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:risk_tier, @risk_tiers)
  end
end
