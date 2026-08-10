defmodule AOS.AgentOS.Core.DAGNode do
  @moduledoc "Persistent state for one node attempt in a DAG run."

  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(pending ready running succeeded failed skipped cancelled)

  schema "agent_dag_nodes" do
    field :dag_run_id, Ecto.UUID
    field :node_id, :string
    field :component_id, :string
    field :status, :string, default: "pending"
    field :outcome, :string
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 1
    field :timeout_ms, :integer
    field :idempotency_key, :string
    field :input, :map, default: %{}
    field :output, :map, default: %{}
    field :error_message, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :dag_run_id,
      :node_id,
      :component_id,
      :status,
      :outcome,
      :attempt,
      :max_attempts,
      :timeout_ms,
      :idempotency_key,
      :input,
      :output,
      :error_message,
      :started_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([:dag_run_id, :node_id, :component_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:max_attempts, greater_than: 0)
    |> unique_constraint(:node_id, name: :agent_dag_nodes_dag_run_id_node_id_index)
    |> unique_constraint(:idempotency_key)
  end
end
