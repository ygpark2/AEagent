defmodule AOS.AgentOS.Orchestration.MetaCoordinator do
  @moduledoc "Coordinates independent orchestrators through durable, broadcast events."

  use GenServer
  alias AOS.AgentOS.Orchestration.{DAGEngine, DAGStore, EventProtocol}
  alias AOS.AgentOS.TaskSupervisor
  require Logger

  @topic_prefix "aos:orchestration:"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def emit(event) when is_map(event) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:emit, event})
    else
      persist_and_broadcast(event)
    end
  end

  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(AOS.PubSub, topic(run_id))
  end

  def dispatch(definition, context, opts \\ []) do
    Task.Supervisor.start_child(TaskSupervisor, fn -> DAGEngine.run(definition, context, opts) end)
  end

  def cancel(run_id) do
    with {:ok, run} <- DAGStore.request_cancel(run_id),
         {:ok, event} <-
           emit(
             EventProtocol.new("orchestration.cancel_requested", %{
               run_id: run.id,
               execution_id: run.execution_id,
               orchestrator_id: run.orchestrator_id,
               idempotency_key: "#{run.id}:orchestration.cancel_requested:run",
               payload: %{reason: "requested"}
             })
           ) do
      {:ok, event}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{active: %{}}}

  @impl true
  def handle_call({:emit, event}, _from, state) do
    result = persist_and_broadcast(event)
    run_id = Map.get(event, :run_id)
    {:reply, result, put_active(state, run_id, event)}
  end

  defp persist_and_broadcast(event) do
    if EventProtocol.valid?(event) do
      with {:ok, persisted} <-
             DAGStore.append_event(%{
               dag_run_id: Map.get(event, :run_id),
               execution_id: Map.get(event, :execution_id),
               node_id: Map.get(event, :node_id),
               orchestrator_id: Map.get(event, :orchestrator_id, "dag"),
               event_type: Map.get(event, :event_type),
               source: Map.get(event, :source, "orchestrator"),
               payload:
                 Map.merge(Map.get(event, :payload, %{}), %{
                   event_id: Map.get(event, :event_id),
                   version: 1
                 }),
               idempotency_key: Map.get(event, :idempotency_key)
             }) do
        broadcast(event)
        {:ok, Map.put(event, :persisted_event_id, persisted.id)}
      end
    else
      Logger.warning("[MetaCoordinator] Ignoring invalid orchestration event: #{inspect(event)}")
      {:error, :invalid_orchestration_event}
    end
  end

  defp broadcast(event) do
    case Map.get(event, :run_id) do
      nil ->
        :ok

      run_id ->
        if Process.whereis(AOS.PubSub),
          do: Phoenix.PubSub.broadcast(AOS.PubSub, topic(run_id), {:orchestration_event, event}),
          else: :ok
    end
  end

  defp put_active(state, nil, _event), do: state

  defp put_active(state, run_id, event) do
    put_in(state, [:active, run_id], %{
      orchestrator_id: Map.get(event, :orchestrator_id),
      last_event: event
    })
  end

  defp topic(run_id), do: @topic_prefix <> to_string(run_id)
end
