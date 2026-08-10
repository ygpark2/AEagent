defmodule AOS.AgentOS.Orchestration do
  @moduledoc "Public facade for durable DAG orchestration and coordination."

  alias AOS.AgentOS.Orchestration.{DAGEngine, DAGStore, MetaCoordinator}

  def run(definition, context \\ %{}, opts \\ []),
    do: DAGEngine.run(definition, context, opts)

  def dispatch(definition, context \\ %{}, opts \\ []),
    do: MetaCoordinator.dispatch(definition, context, opts)

  def cancel(run_id), do: DAGEngine.cancel(run_id)
  def resume(run_id, opts \\ []), do: DAGEngine.resume(run_id, opts)
  def get_run(run_id), do: DAGStore.get_run(run_id)
  def list_nodes(run_id), do: DAGStore.list_nodes(run_id)
  def list_edges(run_id), do: DAGStore.list_edges(run_id)
  def list_events(run_id, limit \\ 100), do: DAGStore.list_events(run_id, limit)
end
