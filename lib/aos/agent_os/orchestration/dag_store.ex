defmodule AOS.AgentOS.Orchestration.DAGStore do
  @moduledoc "Persistence boundary for DAG runs, nodes, edges, and protocol events."

  import Ecto.Query

  alias AOS.AgentOS.Core.{DAGEdge, DAGEvent, DAGNode, DAGRun}
  alias AOS.Repo

  def get_run(id), do: Repo.get(DAGRun, id)
  def get_run!(id), do: Repo.get!(DAGRun, id)

  def get_run_by_execution(execution_id) do
    DAGRun
    |> where([r], r.execution_id == ^execution_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_run_by_idempotency(nil), do: nil

  def get_run_by_idempotency(key) do
    Repo.get_by(DAGRun, idempotency_key: key)
  end

  def create_run(attrs) do
    %DAGRun{}
    |> DAGRun.changeset(attrs)
    |> Repo.insert()
  end

  def update_run(id, attrs) do
    id
    |> get_run!()
    |> DAGRun.changeset(attrs)
    |> Repo.update()
  end

  def request_cancel(id) do
    update_run(id, %{cancellation_requested: true})
  end

  def cancel_requested?(id) do
    case get_run(id) do
      %DAGRun{cancellation_requested: true} -> true
      _ -> false
    end
  end

  def create_node(attrs) do
    %DAGNode{}
    |> DAGNode.changeset(attrs)
    |> Repo.insert()
  end

  def create_nodes(attrs_list), do: Enum.map(attrs_list, &create_node/1)

  def get_node(run_id, node_id) do
    Repo.get_by(DAGNode, dag_run_id: run_id, node_id: to_string(node_id))
  end

  def list_nodes(run_id) do
    DAGNode
    |> where([n], n.dag_run_id == ^run_id)
    |> order_by([n], asc: n.inserted_at)
    |> Repo.all()
  end

  def update_node(%DAGNode{} = node, attrs) do
    node
    |> DAGNode.changeset(attrs)
    |> Repo.update()
  end

  def update_node(id, attrs), do: id |> Repo.get!(DAGNode) |> update_node(attrs)

  def create_edge(attrs) do
    %DAGEdge{}
    |> DAGEdge.changeset(attrs)
    |> Repo.insert()
  end

  def create_edges(attrs_list), do: Enum.map(attrs_list, &create_edge/1)

  def list_edges(run_id) do
    DAGEdge
    |> where([e], e.dag_run_id == ^run_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def append_event(attrs) do
    case Map.get(attrs, :idempotency_key) do
      nil ->
        insert_event(attrs)

      key ->
        case Repo.get_by(DAGEvent, dag_run_id: Map.get(attrs, :dag_run_id), idempotency_key: key) do
          nil -> insert_event(attrs)
          event -> {:ok, event}
        end
    end
  end

  defp insert_event(attrs) do
    attrs = Map.put_new(attrs, :position, next_event_position(Map.get(attrs, :dag_run_id)))

    %DAGEvent{}
    |> DAGEvent.changeset(attrs)
    |> Repo.insert()
  end

  def list_events(run_id, limit \\ 100) do
    DAGEvent
    |> where([e], e.dag_run_id == ^run_id)
    |> order_by([e], asc: e.position, asc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def serialize_event(%DAGEvent{} = event) do
    %{
      id: event.id,
      dag_run_id: event.dag_run_id,
      execution_id: event.execution_id,
      node_id: event.node_id,
      orchestrator_id: event.orchestrator_id,
      event_type: event.event_type,
      source: event.source,
      payload: event.payload,
      idempotency_key: event.idempotency_key,
      position: event.position,
      inserted_at: event.inserted_at
    }
  end

  defp next_event_position(nil), do: 0

  defp next_event_position(run_id) do
    DAGEvent
    |> where([e], e.dag_run_id == ^run_id)
    |> select([e], max(e.position))
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end
end
