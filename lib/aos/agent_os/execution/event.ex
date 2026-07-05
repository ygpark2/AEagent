defmodule AOS.AgentOS.Execution.Event do
  @moduledoc """
  Append-only execution timeline event.
  """
  use AOS.Schema
  import Ecto.Changeset

  schema "agent_execution_events" do
    field :execution_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :workflow_id, Ecto.UUID
    field :event_type, :string
    field :source, :string
    field :payload, :map, default: %{}
    field :position, :integer, default: 0

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :execution_id,
      :session_id,
      :workflow_id,
      :event_type,
      :source,
      :payload,
      :position
    ])
    |> validate_required([:event_type, :payload, :position])
  end
end
