defmodule AOS.AgentOS.Core.DAGRun do
  @moduledoc "Persistent state for a DAG orchestration run."

  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(queued running succeeded failed blocked cancelled)

  schema "agent_dag_runs" do
    field :execution_id, Ecto.UUID
    field :workflow_id, Ecto.UUID
    field :parent_run_id, Ecto.UUID
    field :orchestrator_id, :string, default: "dag"
    field :status, :string, default: "queued"
    field :definition, :map, default: %{}
    field :base_context, :map, default: %{}
    field :retry_policy, :map, default: %{}
    field :timeout_ms, :integer
    field :cancellation_requested, :boolean, default: false
    field :idempotency_key, :string
    field :result, :map
    field :error_message, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :execution_id,
      :workflow_id,
      :parent_run_id,
      :orchestrator_id,
      :status,
      :definition,
      :base_context,
      :retry_policy,
      :timeout_ms,
      :cancellation_requested,
      :idempotency_key,
      :result,
      :error_message,
      :started_at,
      :finished_at,
      :heartbeat_at,
      :metadata
    ])
    |> validate_required([:status, :definition])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:idempotency_key)
  end
end
