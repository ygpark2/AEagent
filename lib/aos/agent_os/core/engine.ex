defmodule AOS.AgentOS.Core.Engine do
  @moduledoc """
  The execution engine for Agent Graphs. 
  Reports node modules to UI for accurate result display.
  """
  require Logger
  alias AOS.AgentOS.Core.Graph
  alias AOS.AgentOS.Execution.CheckpointService
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Policies.{BudgetPolicy, DomainPolicy, SafetyPolicy}

  @active_policies [SafetyPolicy, BudgetPolicy, DomainPolicy]

  def run(%Graph{} = graph, initial_context, opts \\ []) do
    Logger.info("Starting Agent Graph execution: #{graph.id}")
    initial_context = CheckpointService.to_runtime_map(initial_context)
    notify_pid = Keyword.get(opts, :notify)
    start_node = Map.get(initial_context, :resume_from_node) || graph.initial_node

    with {:ok, _execution, context} <- Executions.ensure_execution(initial_context),
         {:ok, _execution} <-
           Executions.mark_running(context.execution_id, %{
             domain: Map.get(context, :domain, "general"),
             strategy_id: Map.get(context, :strategy_id)
           }) do
      context =
        context
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

    case check_policies(@active_policies, context, node_id) do
      {:ok, updated_context} ->
        perform_node_execution(graph, node_id, node_module, updated_context, notify_pid)

      {:error, reason} ->
        Logger.error("Execution blocked by policy: #{inspect(reason)}")
        Executions.block_execution(context.execution_id, context, reason)
        if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})
        {:error, node_id, reason, context}
    end
  end

  defp check_policies(policies, context, node_id) do
    Enum.reduce_while(policies, {:ok, context}, fn policy, {:ok, acc_context} ->
      case policy.check(acc_context, node_id) do
        {:ok, new_context} -> {:cont, {:ok, new_context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
        next_node_id = find_next_node(graph, node_id, outcome)
        Executions.record_step_artifact(final_context, node_id, next_node_id)
        execute_node(graph, next_node_id, final_context, notify_pid)

      {:error, reason} ->
        Logger.error("Node #{node_id} failed: #{inspect(reason)}")
        Executions.fail_execution(context.execution_id, context, reason)
        if notify_pid, do: send(notify_pid, {:workflow_error, node_id, reason})
        {:error, node_id, reason, context}
    end
  end

  defp find_next_node(graph, current_node_id, outcome) do
    transitions = Map.get(graph.transitions, current_node_id, [])

    case Enum.find(transitions, fn t -> t.on == outcome end) do
      %{to: next_id} -> next_id
      nil -> nil
    end
  end
end
