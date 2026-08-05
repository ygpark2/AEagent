defmodule AOS.AgentOS.Core.GoalRun do
  @moduledoc "One bounded attempt to advance a Goal."
  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(queued running succeeded failed blocked waiting)

  def statuses, do: @statuses

  schema "agent_goal_runs" do
    field :goal_id, Ecto.UUID
    field :event_id, Ecto.UUID
    field :execution_id, Ecto.UUID
    field :attempt, :integer, default: 1
    field :status, :string, default: "queued"
    field :verification_result, :map, default: %{}
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error_message, :string

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :goal_id,
      :event_id,
      :execution_id,
      :attempt,
      :status,
      :verification_result,
      :metadata,
      :started_at,
      :finished_at,
      :error_message
    ])
    |> validate_required([:goal_id, :event_id, :attempt, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt, greater_than: 0)
    |> unique_constraint(:event_id)
  end
end
