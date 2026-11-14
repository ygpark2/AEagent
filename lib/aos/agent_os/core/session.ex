defmodule AOS.AgentOS.Core.Session do
  @moduledoc """
  Persistent container for a sequence of executions tied to the same user task/session.
  """
  use AOS.Schema
  import Ecto.Changeset
  alias AOS.AgentOS.Autonomy

  @statuses ~w(active running completed failed blocked archived suspended)

  def statuses, do: @statuses

  schema "agent_sessions" do
    field :title, :string
    field :task, :string
    field :status, :string, default: "active"
    field :autonomy_level, :string, default: "supervised"
    field :metadata, :map, default: %{}
    field :last_execution_id, Ecto.UUID

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:title, :task, :status, :autonomy_level, :metadata, :last_execution_id])
    |> validate_required([:title, :task, :status, :autonomy_level])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:autonomy_level, Autonomy.levels())
  end
end
