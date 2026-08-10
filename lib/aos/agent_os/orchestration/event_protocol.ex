defmodule AOS.AgentOS.Orchestration.EventProtocol do
  @moduledoc "Versioned event contract between meta and child orchestrators."

  @event_types ~w(
    orchestration.started
    orchestration.completed
    orchestration.failed
    orchestration.cancel_requested
    orchestration.cancelled
    node.ready
    node.started
    node.completed
    node.failed
    node.skipped
    join.released
    artifact.published
  )

  def event_types, do: @event_types

  def new(type, attrs \\ %{}) when is_binary(type) do
    %{
      event_id: Ecto.UUID.generate(),
      version: 1,
      event_type: type,
      occurred_at: DateTime.utc_now(),
      run_id: Map.get(attrs, :run_id) || Map.get(attrs, "run_id"),
      parent_run_id: Map.get(attrs, :parent_run_id) || Map.get(attrs, "parent_run_id"),
      execution_id: Map.get(attrs, :execution_id) || Map.get(attrs, "execution_id"),
      node_id: Map.get(attrs, :node_id) || Map.get(attrs, "node_id"),
      orchestrator_id:
        Map.get(attrs, :orchestrator_id) || Map.get(attrs, "orchestrator_id") || "dag",
      source: Map.get(attrs, :source) || Map.get(attrs, "source") || "orchestrator",
      idempotency_key: Map.get(attrs, :idempotency_key) || Map.get(attrs, "idempotency_key"),
      payload: Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{}
    }
  end

  def valid?(%{event_type: type}) when type in @event_types, do: true
  def valid?(_event), do: false
end
