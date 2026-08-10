defmodule AOS.AgentOS.Core.HarnessEpisode do
  @moduledoc "Durable episode package for one agent task under the harness."

  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(queued running succeeded failed blocked cancelled)

  schema "agent_harness_episodes" do
    field :execution_id, Ecto.UUID
    field :dag_run_id, Ecto.UUID
    field :status, :string, default: "queued"
    field :manifest, :map, default: %{}
    field :budget, :map, default: %{}
    field :verification, :map, default: %{}
    field :failure_attribution, :map, default: %{}
    field :summary, :map, default: %{}
    field :intervention_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :execution_id,
      :dag_run_id,
      :status,
      :manifest,
      :budget,
      :verification,
      :failure_attribution,
      :summary,
      :intervention_count,
      :started_at,
      :finished_at
    ])
    |> validate_required([:execution_id, :status, :manifest, :budget])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:execution_id)
  end
end
