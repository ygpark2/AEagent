defmodule AOS.AgentOS.Core.GoalEvent do
  @moduledoc "An external or manual event that asks a Goal to make progress."
  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(queued processing dispatched ignored failed)

  def statuses, do: @statuses

  schema "agent_goal_events" do
    field :goal_id, Ecto.UUID
    field :event_type, :string
    field :source, :string
    field :idempotency_key, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "queued"
    field :processed_at, :utc_datetime_usec
    field :error_message, :string

    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :goal_id,
      :event_type,
      :source,
      :idempotency_key,
      :payload,
      :status,
      :processed_at,
      :error_message
    ])
    |> validate_required([:goal_id, :event_type, :source, :payload, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:idempotency_key)
  end
end
