defmodule AOS.AgentOS.Core.Goal do
  @moduledoc """
  Durable, long-lived objective that can be advanced by multiple executions.
  """
  use AOS.Schema
  import Ecto.Changeset

  alias AOS.AgentOS.Autonomy

  @statuses ~w(draft active paused waiting blocked succeeded failed cancelled expired)
  @goal_types ~w(ongoing one_shot)

  def statuses, do: @statuses
  def goal_types, do: @goal_types

  schema "agent_goals" do
    field :name, :string
    field :objective, :string
    field :description, :string
    field :status, :string, default: "active"
    field :goal_type, :string, default: "ongoing"
    field :trigger, :map, default: %{}
    field :success_criteria, :map, default: %{}
    field :constraints, :map, default: %{}
    field :policy_profile, :map, default: %{}
    field :retry_policy, :map, default: %{}
    field :output_config, :map, default: %{}
    field :context, :map, default: %{}
    field :metadata, :map, default: %{}
    field :autonomy_level, :string, default: "supervised"
    field :owner, :string
    field :version, :integer, default: 1
    field :next_run_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_error, :string

    timestamps()
  end

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [
      :name,
      :objective,
      :description,
      :status,
      :goal_type,
      :trigger,
      :success_criteria,
      :constraints,
      :policy_profile,
      :retry_policy,
      :output_config,
      :context,
      :metadata,
      :autonomy_level,
      :owner,
      :version,
      :next_run_at,
      :last_run_at,
      :completed_at,
      :last_error
    ])
    |> validate_required([:name, :objective, :status, :goal_type])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:goal_type, @goal_types)
    |> validate_inclusion(:autonomy_level, Autonomy.levels())
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:name)
  end
end
