defmodule AOS.AgentOS.Orchestration.NodeDispatcher do
  @moduledoc "Supervised node execution and shared child-orchestration dispatch."

  alias AOS.AgentOS.Autonomy
  alias AOS.AgentOS.Core.{Architect, Engine, PolicyGate}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Harness
  alias AOS.AgentOS.Harness.Budget
  alias AOS.AgentOS.Orchestration.DAGEngine
  alias AOS.AgentOS.TaskSupervisor
  require Logger

  @default_timeout_ms 120_000

  def run_node(node_id, node_module, context, opts \\ []) do
    max_attempts = max(Keyword.get(opts, :max_attempts, 1), 1)
    timeout_ms = max(Keyword.get(opts, :timeout_ms, @default_timeout_ms), 1)
    policy_check = Keyword.get(opts, :policy_check, &PolicyGate.check/2)
    cancel_check = Keyword.get(opts, :cancel_check, fn -> false end)

    case Budget.check_context(context) do
      {:ok, checked_context} ->
        do_run_node(
          node_id,
          node_module,
          checked_context,
          max_attempts,
          timeout_ms,
          policy_check,
          cancel_check,
          1
        )

      {:error, reason} ->
        Harness.record_failure(Map.get(context, :execution_id), reason, context)
        {:error, reason, context, 1}
    end
  end

  def run_child_execution(context, target, index, depth, opts \\ []) do
    notify_pid = Map.get(context, :notify)

    graph_builder =
      Keyword.get(
        opts,
        :graph_builder,
        Map.get(context, :delegation_graph_builder, &Architect.build_graph/2)
      )

    child_engine = Keyword.get(opts, :engine) || Map.get(context, :engine, "graph")

    runner =
      Keyword.get(opts, :runner) ||
        Map.get(context, :delegation_runner) ||
        if child_engine in [:dag, "dag"], do: &DAGEngine.run/3, else: &Engine.run/3

    with {:ok, execution} <-
           Executions.enqueue(target,
             async: false,
             start_immediately: false,
             session_id: Map.get(context, :session_id),
             autonomy_level: Map.get(context, :autonomy_level),
             engine: child_engine,
             harness_manifest: Map.get(context, :harness_manifest),
             success_criteria: Map.get(context, :success_criteria),
             constraints: Map.get(context, :constraints)
           ),
         {:ok, trace} <-
           Executions.create_delegation_trace(%{
             session_id: Map.get(context, :session_id),
             parent_execution_id: Map.get(context, :execution_id),
             child_execution_id: execution.id,
             task: target,
             status: "running",
             position: index
           }) do
      sub_graph = graph_builder.(target, notify: notify_pid)

      sub_context = %{
        task: target,
        history: Map.get(context, :history, []),
        notify: notify_pid,
        delegation_depth: depth + 1,
        cost_usd: 0.0,
        session_id: Map.get(context, :session_id),
        autonomy_level: Map.get(context, :autonomy_level, Autonomy.default_level()),
        selected_skills: Map.get(context, :selected_skills, []),
        skills: Map.get(context, :skills, []),
        engine: child_engine,
        execution_id: execution.id
      }

      case runner.(sub_graph, sub_context, notify: notify_pid) do
        {:ok, child_context} ->
          summary = summarize_result(Map.get(child_context, :result, "Sub-task completed."))

          Executions.update_delegation_trace(trace.id, %{
            status: "succeeded",
            result_summary: summary
          })

          {:ok, execution.id,
           %{task: target, result: Map.get(child_context, :result), summary: summary}}

        {:error, node_id, reason, _child_context} ->
          message = "Delegation failed at #{node_id}: #{inspect(reason)}"

          Executions.update_delegation_trace(trace.id, %{status: "failed", error_message: message})

          {:error, execution.id, %{task: target, reason: reason, message: message}}
      end
    end
  end

  defp do_run_node(
         node_id,
         node_module,
         context,
         max_attempts,
         timeout_ms,
         policy_check,
         cancel_check,
         attempt
       ) do
    trace_node(context, node_id, "started", %{attempt: attempt})

    if cancel_check.() do
      trace_node(context, node_id, "cancelled", %{attempt: attempt})
      {:cancelled, context, attempt}
    else
      do_run_node_after_policy(
        node_id,
        node_module,
        context,
        max_attempts,
        timeout_ms,
        policy_check,
        cancel_check,
        attempt
      )
    end
  end

  defp do_run_node_after_policy(
         node_id,
         node_module,
         context,
         max_attempts,
         timeout_ms,
         policy_check,
         cancel_check,
         attempt
       ) do
    case policy_check.(context, node_id) do
      {:error, reason} ->
        trace_node(context, node_id, "failed", %{attempt: attempt, reason: inspect(reason)})
        {:error, reason, context, attempt}

      {:ok, checked_context} ->
        case execute_once(node_module, checked_context, timeout_ms, cancel_check) do
          {:ok, updated_context} ->
            trace_node(updated_context, node_id, "completed", %{attempt: attempt})
            {:ok, updated_context, attempt}

          {:cancelled, cancelled_context} ->
            trace_node(cancelled_context, node_id, "cancelled", %{attempt: attempt})
            {:cancelled, cancelled_context, attempt}

          {:error, reason} when attempt < max_attempts ->
            Logger.warning(
              "[NodeDispatcher] Retrying node #{node_id} (#{attempt + 1}/#{max_attempts}) after #{inspect(reason)}"
            )

            do_run_node(
              node_id,
              node_module,
              Map.put(checked_context, :node_attempt, attempt + 1),
              max_attempts,
              timeout_ms,
              policy_check,
              cancel_check,
              attempt + 1
            )

          {:error, reason} ->
            trace_node(checked_context, node_id, "failed", %{
              attempt: attempt,
              reason: inspect(reason)
            })

            {:error, reason, checked_context, attempt}
        end
    end
  end

  defp execute_once(node_module, context, timeout_ms, cancel_check) do
    task =
      if Process.whereis(TaskSupervisor) do
        Task.Supervisor.async_nolink(TaskSupervisor, fn -> node_module.run(context, []) end)
      else
        Task.async(fn -> node_module.run(context, []) end)
      end

    await_task(task, timeout_ms, cancel_check, context)
  end

  defp await_task(task, remaining_ms, cancel_check, context) do
    cond do
      cancel_check.() ->
        Task.shutdown(task, :brutal_kill)
        {:cancelled, context}

      remaining_ms <= 0 ->
        Task.shutdown(task, :brutal_kill)
        {:error, :node_timeout}

      true ->
        wait_ms = min(remaining_ms, 100)
        started_at = System.monotonic_time(:millisecond)

        result = Task.yield(task, wait_ms)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        case result do
          {:ok, {:ok, updated_context}} -> {:ok, updated_context}
          {:ok, {:error, reason}} -> {:error, reason}
          {:exit, reason} -> {:error, reason}
          nil -> await_task(task, remaining_ms - elapsed_ms, cancel_check, context)
          other -> {:error, {:invalid_node_result, other}}
        end
    end
  end

  defp summarize_result(result) do
    result
    |> to_string()
    |> String.slice(0, 240)
  end

  defp trace_node(context, node_id, phase, payload) do
    if execution_id = Map.get(context, :execution_id) do
      Harness.trace(execution_id, "node", phase, Map.put(payload, :node_id, to_string(node_id)),
        idempotency_key: "node:#{node_id}:#{phase}:#{Map.get(payload, :attempt, 0)}"
      )
    end
  end
end
