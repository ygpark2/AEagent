defmodule AOS.AgentOS.Core.DAGEvent do
  @moduledoc "Append-only protocol event for orchestrator coordination."

  use AOS.Schema
  import Ecto.Changeset

  schema "agent_dag_events" do
    field :dag_run_id, Ecto.UUID
    field :execution_id, Ecto.UUID
    field :node_id, :string
    field :orchestrator_id, :string, default: "dag"
    field :event_type, :string
    field :source, :string
    field :payload, :map, default: %{}
    field :idempotency_key, :string
    field :position, :integer, default: 0

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :dag_run_id,
      :execution_id,
      :node_id,
      :orchestrator_id,
      :event_type,
      :source,
      :payload,
      :idempotency_key,
      :position
    ])
    |> validate_required([:dag_run_id, :event_type, :payload, :position])
  end
end
