defmodule AOS.AgentOS.Core.Engine do
  @moduledoc """
  The execution engine for Agent Graphs. 
  Reports node modules to UI for accurate result display.
  """
  require Logger
  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Core.Graph
  alias AOS.AgentOS.Core.PolicyGate
  alias AOS.AgentOS.Core.Nodes.{LLMEvaluator, LLMWorker}
  alias AOS.AgentOS.Execution.CheckpointService
  alias AOS.AgentOS.Executions

  def run(%Graph{} = graph, initial_context, opts \\ []) do
    Logger.info("Starting Agent Graph execution: #{graph.id}")
    initial_context = CheckpointService.to_runtime_map(initial_context)
    notify_pid = Keyword.get(opts, :notify)
    start_node = Map.get(initial_context, :resume_from_node) || graph.initial_node

    with {:ok, execution, context} <- Executions.ensure_execution(initial_context),
         {:ok, _execution} <-
           Executions.mark_running(context.execution_id, %{
             domain: Map.get(context, :domain, "general"),
             strategy_id: Map.get(context, :strategy_id)
           }) do
      context =
        context
        |> Map.put_new(:engine, execution.engine || "graph")
        |> Map.put_new(:execution_history, [])
        |> Map.put_new(:history, [])
        |> Map.put(:graph_nodes, graph.nodes)
        |> Map.put(:notify, notify_pid)

      execute_node(graph, start_node, context, notify_pid)
    end
  end

  defp execute_node(_graph, nil, context, _notify_pid) do
    Logger.info("Reached terminal state. Workflow completed.")
    Executions.complete_execution(context.execution_id, context)
    {:ok, context}
  end

  defp execute_node(graph, node_id, context, notify_pid) do
    node_module = Map.get(graph.nodes, node_id)
    context = Map.put(context, :graph_nodes, graph.nodes)

    if notify_pid, do: send(notify_pid, {:workflow_step_started, node_id, node_module})

    case PolicyGate.check(context, node_id) do
      {:ok, updated_context} ->
        perform_node_execution(graph, node_id, node_module, updated_context, notify_pid)

      {:error, reason} ->
        Logger.error("Execution blocked by policy: #{inspect(reason)}")
        Executions.block_execution(context.execution_id, context, reason)
        if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})
        {:error, node_id, reason, context}
    end
  end

  defp perform_node_execution(_graph, node_id, nil, context, notify_pid) do
    reason = "Node #{node_id} not found in graph"
    Logger.error(reason)
    Executions.fail_execution(context.execution_id, context, reason)
    if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})
    {:error, node_id, reason, context}
  end

  defp perform_node_execution(graph, node_id, node_module, context, notify_pid) do
    Logger.info("Executing Node: #{node_id} (#{inspect(node_module)})")

    case node_module.run(context, []) do
      {:ok, updated_context} ->
        outcome = Map.get(updated_context, :last_outcome, :success)

        # Send BOTH node_id and node_module so UI can decide how to render
        if notify_pid,
          do: send(notify_pid, {:workflow_step_completed, node_id, node_module, updated_context})

        step_record = %{
          node_id: node_id,
          outcome: outcome,
          feedback: Map.get(updated_context, :feedback, nil),
          timestamp: DateTime.utc_now()
        }

        final_context = Map.update!(updated_context, :execution_history, &(&1 ++ [step_record]))

        case next_step(graph, node_id, node_module, outcome, final_context) do
          {:ok, next_node_id, next_context} ->
            Executions.record_step_artifact(next_context, node_id, next_node_id)
            execute_node(graph, next_node_id, next_context, notify_pid)

          {:error, reason, failed_context} ->
            Logger.error("Refinement stopped at #{node_id}: #{inspect(reason)}")
            Executions.record_step_artifact(failed_context, node_id, nil)
            Executions.fail_execution(failed_context.execution_id, failed_context, reason)

            if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})

            {:error, node_id, reason, failed_context}
        end

      {:error, reason} ->
        Logger.error("Node #{node_id} failed: #{inspect(reason)}")

        if approval_required?(reason),
          do: Executions.block_execution(context.execution_id, context, reason),
          else: Executions.fail_execution(context.execution_id, context, reason)

        if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})
        {:error, node_id, reason, context}
    end
  end

  defp approval_required?({:approval_required, _request}), do: true
  defp approval_required?(_reason), do: false

  defp next_step(graph, node_id, node_module, :fail, context) do
    if refinement_node?(node_id, node_module) do
      refinement_target = find_refinement_target(graph, node_id)
      attempts = Map.get(context, :refinement_attempts, 0)
      max_attempts = max(Config.max_refinement_attempts(), 0)

      cond do
        is_nil(refinement_target) ->
          {:error, :quality_refinement_unavailable, context}

        attempts >= max_attempts ->
          {:error, :quality_refinement_exhausted, context}

        true ->
          {:ok, refinement_target, Map.put(context, :refinement_attempts, attempts + 1)}
      end
    else
      {:ok, find_next_node(graph, node_id, :fail), context}
    end
  end

  defp next_step(graph, node_id, _node_module, outcome, context) do
    {:ok, find_next_node(graph, node_id, outcome), context}
  end

  defp refinement_node?(_node_id, LLMEvaluator), do: true

  defp refinement_node?(node_id, _node_module) do
    to_string(node_id) in ["critic", "evaluator", "reviewer", "reviewer_agent"]
  end

  defp find_refinement_target(graph, current_node_id) do
    configured_target = find_next_node(graph, current_node_id, :fail)

    if valid_refinement_target?(graph, configured_target, current_node_id) do
      configured_target
    else
      graph.transitions
      |> Enum.flat_map(fn {from_id, transitions} ->
        if Enum.any?(transitions, &(&1.to == current_node_id)), do: [from_id], else: []
      end)
      |> Enum.reject(&(&1 == current_node_id))
      |> Enum.sort_by(fn node_id -> if llm_worker_node?(graph, node_id), do: 0, else: 1 end)
      |> List.first()
    end
  end

  defp valid_refinement_target?(graph, target, current_node_id) do
    target not in [nil, current_node_id] and
      Map.has_key?(graph.nodes, target) and
      to_string(target) not in ["reporter", "critic", "evaluator", "reviewer"]
  end

  defp llm_worker_node?(graph, node_id) do
    Map.get(graph.nodes, node_id) == LLMWorker or to_string(node_id) in ["thinker", "worker"]
  end

  defp find_next_node(graph, current_node_id, outcome) do
    transitions = Map.get(graph.transitions, current_node_id, [])

    case Enum.find(transitions, fn t -> t.on == outcome end) do
      %{to: next_id} -> next_id
      nil -> nil
    end
  end
end
