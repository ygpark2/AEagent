defmodule AOS.AgentOS.Core.Execution do
  @moduledoc """
  Schema for tracking agent execution history in the DB.
  """
  use AOS.Schema
  import Ecto.Changeset
  alias AOS.AgentOS.Autonomy

  @statuses ~w(queued running succeeded failed blocked)

  def statuses, do: @statuses

  schema "agent_executions" do
    field :session_id, Ecto.UUID
    field :goal_id, Ecto.UUID
    field :source_execution_id, Ecto.UUID
    field :workflow_id, Ecto.UUID
    field :engine, :string, default: "graph"
    field :domain, :string
    field :task, :string
    field :status, :string, default: "queued"
    field :trigger_kind, :string
    field :autonomy_level, :string, default: "supervised"
    field :strategy_id, Ecto.UUID
    field :fitness_score, :float
    field :quality_score, :float
    field :failure_category, :string
    field :success, :boolean, default: false
    field :execution_log, :map
    field :final_result, :string
    field :error_message, :string
    field :embedding, :binary
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :domain,
      :task,
      :session_id,
      :goal_id,
      :source_execution_id,
      :workflow_id,
      :engine,
      :status,
      :trigger_kind,
      :autonomy_level,
      :strategy_id,
      :fitness_score,
      :quality_score,
      :failure_category,
      :success,
      :execution_log,
      :final_result,
      :error_message,
      :embedding,
      :started_at,
      :finished_at
    ])
    |> validate_required([:domain, :task])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:autonomy_level, Autonomy.levels())
  end
end
