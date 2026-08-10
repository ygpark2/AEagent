defmodule AOS.AgentOS.Orchestration.DAGEngine do
  @moduledoc "Durable fan-out/fan-in DAG execution engine."

  alias AOS.AgentOS.Core.{DAGRun, Graph, PolicyGate}
  alias AOS.AgentOS.Execution.ArtifactRecorder
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Harness

  alias AOS.AgentOS.Orchestration.{
    DAGDefinition,
    DAGStore,
    EventProtocol,
    MetaCoordinator,
    NodeDispatcher
  }

  require Logger

  @default_timeout_ms 120_000
  @terminal_statuses ~w(succeeded failed skipped cancelled)

  def run(definition, context, opts \\ [])

  def run(%Graph{} = graph, context, opts),
    do: run(DAGDefinition.from_graph(graph), context, opts)

  def run(definition, initial_context, opts) do
    with {:ok, dag} <- DAGDefinition.normalize(definition) do
      case existing_idempotent_run(initial_context, opts) do
        nil ->
          start_run(dag, initial_context, opts)

        %DAGRun{status: status} = run when status in ~w(succeeded failed blocked cancelled) ->
          {:ok, terminal_context(initial_context, run)}

        %DAGRun{status: status} = run when status in ~w(queued running) ->
          {:error, {:dag_already_running, run.id, status}}
      end
    end
  end

  defp start_run(dag, initial_context, opts) do
    with {:ok, _execution, context} <-
           Executions.ensure_execution(
             initial_context
             |> Map.put(:engine, "dag")
             |> Map.put(:notify, Keyword.get(opts, :notify))
           ),
         {:ok, run} <- ensure_run(dag, context, opts) do
      execute_or_return(dag, context, run, opts)
    end
  end

  defp existing_idempotent_run(context, opts) do
    key = Keyword.get(opts, :idempotency_key) || Map.get(context, :idempotency_key)
    if is_nil(key), do: nil, else: DAGStore.get_run_by_idempotency(key)
  end

  def cancel(run_id), do: MetaCoordinator.cancel(run_id)

  def status(run_id), do: DAGStore.get_run(run_id)

  def resume(run_id, opts \\ []) do
    case DAGStore.get_run(run_id) do
      nil ->
        {:error, :dag_run_not_found}

      %DAGRun{} = run ->
        with {:ok, dag} <- DAGDefinition.normalize(run.definition) do
          context = restore_context(run.base_context) |> Map.put(:execution_id, run.execution_id)
          execute_or_return(dag, context, run, opts)
        end
    end
  end

  defp ensure_run(dag, context, opts) do
    execution_id = Map.get(context, :execution_id)

    idempotency_key =
      Keyword.get(opts, :idempotency_key) || Map.get(context, :idempotency_key) ||
        "execution:#{execution_id}"

    case DAGStore.get_run_by_idempotency(idempotency_key) do
      %{status: status} = run when status in ~w(succeeded failed blocked cancelled) ->
        {:ok, run}

      %{status: status} = run when status in ~w(queued running) ->
        {:error, {:dag_already_running, run.id, status}}

      nil ->
        create_run(dag, context, opts, idempotency_key)
    end
  end

  defp create_run(dag, context, opts, idempotency_key) do
    timeout_ms =
      positive_integer(Keyword.get(opts, :timeout_ms, default_timeout(dag)), @default_timeout_ms)

    orchestrator_id = to_string(Keyword.get(opts, :orchestrator_id, "dag"))

    with {:ok, _execution} <-
           Executions.mark_running(Map.fetch!(context, :execution_id), %{
             engine: "dag",
             domain: to_string(dag.domain),
             workflow_id: Map.get(context, :workflow_id)
           }),
         {:ok, run} <-
           DAGStore.create_run(%{
             execution_id: Map.get(context, :execution_id),
             workflow_id: Map.get(context, :workflow_id),
             parent_run_id: Keyword.get(opts, :parent_run_id),
             orchestrator_id: orchestrator_id,
             status: "running",
             definition: DAGDefinition.serialize(dag),
             base_context: json_value(context),
             retry_policy: Keyword.get(opts, :retry_policy, %{}),
             timeout_ms: timeout_ms,
             idempotency_key: idempotency_key,
             started_at: DateTime.utc_now(),
             heartbeat_at: DateTime.utc_now(),
             metadata: Keyword.get(opts, :metadata, %{})
           }),
         {:ok, _nodes} <- create_persisted_nodes(run, dag),
         {:ok, _edges} <- create_persisted_edges(run, dag),
         {:ok, _episode} <- Harness.attach_dag_run(run.execution_id, run.id) do
      emit(run, "orchestration.started", %{payload: %{node_count: map_size(dag.nodes)}})
      {:ok, run}
    end
  end

  defp create_persisted_nodes(run, dag) do
    dag.nodes
    |> Enum.map(fn {node_id, module} ->
      options = Map.get(dag.node_options, node_id, %{})
      max_attempts = node_max_attempts(options, %{})
      timeout_ms = positive_or_nil(fetch_option(options, :timeout_ms))

      %{
        dag_run_id: run.id,
        node_id: to_string(node_id),
        component_id: component_id(module),
        status: "pending",
        max_attempts: max_attempts,
        timeout_ms: timeout_ms,
        idempotency_key: "#{run.id}:node:#{node_id}",
        metadata: json_value(options)
      }
    end)
    |> DAGStore.create_nodes()
    |> collect_results()
  end

  defp create_persisted_edges(run, dag) do
    dag.edges
    |> Enum.map(fn edge ->
      %{
        dag_run_id: run.id,
        from_node_id: to_string(edge.from),
        to_node_id: to_string(edge.to),
        on: if(is_nil(edge.on), do: nil, else: to_string(edge.on)),
        condition: json_value(edge.condition || %{}),
        metadata: json_value(edge.metadata || %{})
      }
    end)
    |> DAGStore.create_edges()
    |> collect_results()
  end

  defp execute_or_return(dag, context, %DAGRun{} = run, opts) do
    if run.status in ~w(succeeded failed blocked cancelled) do
      {:ok, terminal_context(context, run)}
    else
      states = load_states(run.id)
      orchestrate(dag, context, run, states, %{}, [], monotonic_ms(), opts)
    end
  end

  defp orchestrate(dag, base_context, run, states, contexts, history, started_at, opts) do
    DAGStore.update_run(run.id, %{heartbeat_at: DateTime.utc_now(), status: "running"})

    cond do
      DAGStore.cancel_requested?(run.id) ->
        finish_cancelled(run, base_context, states, history)

      timed_out?(run, started_at) ->
        finish_failed(run, base_context, states, history, :dag_timeout)

      all_terminal?(states) ->
        finish_terminal(dag, run, base_context, states, contexts, history)

      true ->
        ready = ready_nodes(dag, states)

        if ready == [] do
          {next_states, skipped?} = skip_unreachable_nodes(dag, states, run)

          if skipped? do
            orchestrate(dag, base_context, run, next_states, contexts, history, started_at, opts)
          else
            finish_failed(run, base_context, states, history, :dag_deadlock)
          end
        else
          ready_states = mark_ready(dag, states, ready, run)

          results =
            dispatch_ready(dag, run, ready, ready_states, base_context, contexts, history, opts)

          {next_states, next_contexts, next_history} =
            apply_results(dag, run, ready_states, results, contexts, history)

          if fail_fast?(dag) and
               Enum.any?(next_states, fn {_id, state} -> state.status == "failed" end) do
            finish_failed(
              run,
              base_context,
              next_states,
              next_contexts,
              next_history,
              failed_reason(next_states)
            )
          else
            orchestrate(
              dag,
              base_context,
              run,
              next_states,
              next_contexts,
              next_history,
              started_at,
              opts
            )
          end
        end
    end
  end

  defp dispatch_ready(dag, run, ready, states, base_context, contexts, history, opts) do
    max_concurrency =
      positive_integer(Keyword.get(opts, :max_concurrency, length(ready)), length(ready))

    task_fun = fn node_id ->
      state = Map.fetch!(states, node_id)
      node_context = node_context(dag, run, node_id, base_context, contexts, history)
      options = Map.get(dag.node_options, node_id, %{})
      node_record = state.record
      max_attempts = node_max_attempts(options, run.retry_policy)

      timeout_ms =
        positive_integer(
          fetch_option(options, :timeout_ms) || node_record.timeout_ms,
          run.timeout_ms || @default_timeout_ms
        )

      emit(run, "node.started", %{node_id: node_id, payload: %{attempt: node_record.attempt + 1}})

      NodeDispatcher.run_node(node_id, dag.nodes[node_id], node_context,
        max_attempts: max_attempts,
        timeout_ms: timeout_ms,
        cancel_check: fn -> DAGStore.cancel_requested?(run.id) end
      )
    end

    if Process.whereis(AOS.AgentOS.TaskSupervisor) do
      Task.Supervisor.async_stream_nolink(
        AOS.AgentOS.TaskSupervisor,
        ready,
        task_fun,
        ordered: true,
        max_concurrency: max_concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason, %{}, 1}
      end)
    else
      Task.async_stream(ready, task_fun,
        ordered: true,
        max_concurrency: max_concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason, %{}, 1}
      end)
    end
  end

  defp apply_results(dag, run, states, results, contexts, history) do
    ready =
      states
      |> Enum.filter(fn {_node_id, state} -> state.status == "ready" end)
      |> Enum.map(&elem(&1, 0))

    Enum.zip(ready, results)
    |> Enum.reduce({states, contexts, history}, fn {node_id, result},
                                                   {state_acc, context_acc, history_acc} ->
      state = Map.fetch!(state_acc, node_id)

      case result do
        {:ok, updated_context, attempt} ->
          outcome = Map.get(updated_context, :last_outcome, :success)
          step = step_record(node_id, outcome, updated_context)
          next_history = history_acc ++ [step]
          node_context = Map.put(updated_context, :execution_history, next_history)
          successors = DAGDefinition.successors(dag, node_id, outcome)

          DAGStore.update_node(state.record, %{
            status: "succeeded",
            outcome: to_string(outcome),
            attempt: attempt,
            output: node_output(node_context),
            finished_at: DateTime.utc_now()
          })

          ArtifactRecorder.record_step_artifact(node_context, node_id, List.first(successors))

          emit(run, "artifact.published", %{
            node_id: node_id,
            payload: %{artifact_type: "step", successor: List.first(successors)}
          })

          emit(run, "node.completed", %{
            node_id: node_id,
            payload: %{outcome: to_string(outcome), attempt: attempt}
          })

          {
            Map.put(state_acc, node_id, %{
              state
              | status: "succeeded",
                outcome: to_string(outcome),
                context: node_context,
                attempt: attempt
            }),
            Map.put(context_acc, node_id, node_context),
            next_history
          }

        {:error, reason, failed_context, attempt} ->
          step = step_record(node_id, :error, failed_context)
          next_history = history_acc ++ [step]
          node_context = Map.put(failed_context, :execution_history, next_history)

          DAGStore.update_node(state.record, %{
            status: "failed",
            outcome: "error",
            attempt: attempt,
            output: node_output(node_context),
            error_message: inspect(reason),
            finished_at: DateTime.utc_now()
          })

          ArtifactRecorder.record_step_artifact(node_context, node_id, nil)

          emit(run, "node.failed", %{
            node_id: node_id,
            payload: %{reason: inspect(reason), attempt: attempt}
          })

          {
            Map.put(state_acc, node_id, %{
              state
              | status: "failed",
                outcome: "error",
                context: node_context,
                attempt: attempt,
                error: reason
            }),
            Map.put(context_acc, node_id, node_context),
            next_history
          }

        {:cancelled, cancelled_context, attempt} ->
          next_history = history_acc
          node_context = Map.put(cancelled_context, :execution_history, next_history)

          DAGStore.update_node(state.record, %{
            status: "cancelled",
            outcome: "cancelled",
            attempt: attempt,
            output: node_output(node_context),
            finished_at: DateTime.utc_now()
          })

          emit(run, "node.skipped", %{
            node_id: node_id,
            payload: %{reason: "cancellation_requested"}
          })

          {
            Map.put(state_acc, node_id, %{state | status: "cancelled", context: node_context}),
            Map.put(context_acc, node_id, node_context),
            next_history
          }
      end
    end)
  end

  defp ready_nodes(dag, states) do
    states
    |> Enum.filter(fn {_node_id, state} -> state.status == "pending" end)
    |> Enum.filter(fn {node_id, _state} -> node_ready?(dag, states, node_id) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp node_ready?(dag, states, node_id) do
    predecessors = DAGDefinition.predecessors(dag, node_id)

    if predecessors == [] do
      node_id in dag.initial_nodes
    else
      sources = predecessors |> Enum.map(& &1.from) |> Enum.uniq()
      terminal_sources = Enum.filter(sources, &terminal_node?(Map.get(states, &1)))

      matched_sources =
        predecessors
        |> Enum.filter(fn edge ->
          case Map.get(states, edge.from) do
            %{status: "succeeded", outcome: outcome} -> outcome_matches?(edge.on, outcome)
            _ -> false
          end
        end)
        |> Enum.map(& &1.from)
        |> Enum.uniq()

      policy = DAGDefinition.join_policy(dag, node_id)
      all_settled? = MapSet.new(terminal_sources) == MapSet.new(sources)
      matched_count = length(matched_sources)

      case Map.get(policy, :mode, "all") |> to_string() do
        "any" -> matched_count >= 1
        "best_effort" -> all_settled? and matched_count >= 1
        "quorum" -> matched_count >= quorum_count(policy, length(sources))
        _ -> all_settled? and matched_count == length(sources)
      end
    end
  end

  defp skip_unreachable_nodes(dag, states, run) do
    candidates =
      states
      |> Enum.filter(fn {_id, state} -> state.status == "pending" end)
      |> Enum.filter(fn {id, _state} ->
        DAGDefinition.predecessors(dag, id) != [] and all_predecessors_terminal?(dag, states, id)
      end)

    if candidates == [] do
      {states, false}
    else
      next_states =
        Enum.reduce(candidates, states, fn {node_id, state}, acc ->
          DAGStore.update_node(state.record, %{status: "skipped", finished_at: DateTime.utc_now()})

          emit(run, "node.skipped", %{
            node_id: node_id,
            payload: %{reason: "join_condition_not_met"}
          })

          Map.put(acc, node_id, %{state | status: "skipped"})
        end)

      {next_states, true}
    end
  end

  defp finish_terminal(dag, run, base_context, states, contexts, history) do
    failed? = Enum.any?(states, fn {_id, state} -> state.status == "failed" end)

    if failed? and not fail_fast?(dag) do
      finish_success(dag, run, base_context, states, contexts, history)
    else
      if failed?,
        do: finish_failed(run, base_context, states, contexts, history, failed_reason(states)),
        else: finish_success(dag, run, base_context, states, contexts, history)
    end
  end

  defp finish_success(_dag, run, base_context, _states, contexts, history) do
    final_context = final_context(base_context, contexts, history)

    DAGStore.update_run(run.id, %{
      status: "succeeded",
      result: node_output(final_context),
      finished_at: DateTime.utc_now()
    })

    emit(run, "orchestration.completed", %{payload: %{status: "succeeded"}})
    Executions.complete_execution(run.execution_id, final_context)
    {:ok, final_context}
  end

  defp finish_failed(run, base_context, states, history, reason),
    do: finish_failed(run, base_context, states, %{}, history, reason)

  defp finish_failed(run, base_context, _states, contexts, history, reason) do
    if PolicyGate.blocking_reason?(reason) do
      finish_blocked(run, base_context, contexts, history, reason)
    else
      finish_failed_run(run, base_context, contexts, history, reason)
    end
  end

  defp finish_failed_run(run, base_context, contexts, history, reason) do
    final_context = final_context(base_context, contexts, history)

    DAGStore.update_run(run.id, %{
      status: "failed",
      result: node_output(final_context),
      error_message: inspect(reason),
      finished_at: DateTime.utc_now()
    })

    emit(run, "orchestration.failed", %{payload: %{reason: inspect(reason)}})
    Executions.fail_execution(run.execution_id, final_context, reason)
    {:error, :dag, reason, final_context}
  end

  defp finish_blocked(run, base_context, contexts, history, reason) do
    final_context = final_context(base_context, contexts, history)

    DAGStore.update_run(run.id, %{
      status: "blocked",
      result: node_output(final_context),
      error_message: inspect(reason),
      finished_at: DateTime.utc_now()
    })

    emit(run, "orchestration.failed", %{payload: %{status: "blocked", reason: inspect(reason)}})
    Executions.block_execution(run.execution_id, final_context, reason)
    {:error, :dag, reason, final_context}
  end

  defp finish_cancelled(run, base_context, _states, history) do
    final_context = Map.put(base_context, :execution_history, history)

    DAGStore.update_run(run.id, %{
      status: "cancelled",
      finished_at: DateTime.utc_now(),
      error_message: "cancelled"
    })

    emit(run, "orchestration.cancelled", %{payload: %{reason: "requested"}})
    Executions.block_execution(run.execution_id, final_context, :dag_cancelled)
    {:error, :dag, :cancelled, final_context}
  end

  defp load_states(run_id) do
    run_id
    |> DAGStore.list_nodes()
    |> Map.new(fn record ->
      {record.node_id,
       %{
         record: record,
         status: recoverable_status(record.status),
         outcome: record.outcome,
         attempt: record.attempt,
         context: %{}
       }}
    end)
  end

  defp recoverable_status(status) when status in ["ready", "running"], do: "pending"
  defp recoverable_status(status), do: status

  defp mark_ready(dag, states, ready, run) do
    Enum.reduce(ready, states, fn node_id, acc ->
      state = Map.fetch!(acc, node_id)
      DAGStore.update_node(state.record, %{status: "ready"})
      emit(run, "node.ready", %{node_id: node_id})

      predecessors =
        DAGDefinition.predecessors(dag, node_id)
        |> Enum.map(& &1.from)
        |> Enum.uniq()

      if length(predecessors) > 1 do
        emit(run, "join.released", %{
          node_id: node_id,
          payload: %{sources: predecessors, policy: DAGDefinition.join_policy(dag, node_id)}
        })
      end

      Map.put(acc, node_id, %{state | status: "ready"})
    end)
  end

  defp node_context(dag, run, node_id, base_context, contexts, history) do
    predecessors = DAGDefinition.predecessors(dag, node_id) |> Enum.map(& &1.from) |> Enum.uniq()

    predecessor_contexts =
      Enum.map(predecessors, &Map.get(contexts, &1)) |> Enum.reject(&is_nil/1)

    inherited = Enum.reduce(predecessor_contexts, base_context, &Map.merge(&2, &1))

    inputs =
      Map.new(predecessors, fn predecessor ->
        predecessor_context = Map.get(contexts, predecessor, %{})
        {to_string(predecessor), node_output(predecessor_context)}
      end)

    inherited
    |> Map.put(:dag_run_id, run.id)
    |> Map.put(:dag_node_id, node_id)
    |> Map.put(:graph_nodes, dag.nodes)
    |> Map.put(:execution_history, history)
    |> Map.put(:dag_inputs, inputs)
    |> maybe_put_dag_result(inputs)
  end

  defp maybe_put_dag_result(context, inputs) when map_size(inputs) == 0, do: context

  defp maybe_put_dag_result(context, inputs) do
    rendered =
      inputs
      |> Enum.map_join("\n\n", fn {node_id, output} -> "[#{node_id}]\n#{inspect(output)}" end)

    Map.put(context, :result, rendered)
  end

  defp final_context(base_context, contexts, history) do
    last_context =
      contexts
      |> Map.values()
      |> Enum.reverse()
      |> Enum.find(&Map.has_key?(&1, :result)) || %{}

    base_context
    |> Map.merge(last_context)
    |> Map.put(:execution_history, history)
  end

  defp terminal_context(context, run) do
    context
    |> Map.put(:execution_id, run.execution_id)
    |> Map.put(:execution_history, [])
    |> Map.put(:result, get_in(run.result || %{}, ["result"]) || Map.get(context, :result))
  end

  defp restore_context(context) when is_map(context) do
    Enum.reduce(
      ~w(task history feedback result execution_result cost_usd estimated_cost selected_skills skills goal_id goal_event_id goal_run_id goal_name goal_objective goal_success_criteria goal_constraints goal_context goal_event execution_id workflow_id session_id autonomy_level strategy_id domain engine)a,
      context,
      fn key, acc ->
        string_key = Atom.to_string(key)

        if Map.has_key?(acc, string_key),
          do: Map.put(acc, key, Map.get(acc, string_key)),
          else: acc
      end
    )
  end

  defp restore_context(context), do: context

  defp step_record(node_id, outcome, context) do
    %{
      node_id: node_id,
      outcome: outcome,
      feedback: Map.get(context, :feedback),
      timestamp: DateTime.utc_now()
    }
  end

  defp node_output(context) do
    %{
      "result" => json_value(Map.get(context, :result)),
      "last_outcome" => json_value(Map.get(context, :last_outcome)),
      "feedback" => json_value(Map.get(context, :feedback)),
      "evaluation_score" => json_value(Map.get(context, :evaluation_score)),
      "evaluation_feedback" => json_value(Map.get(context, :evaluation_feedback))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp outcome_matches?(nil, _outcome), do: true
  defp outcome_matches?(expected, outcome), do: to_string(expected) == to_string(outcome)

  defp all_predecessors_terminal?(dag, states, node_id) do
    dag
    |> DAGDefinition.predecessors(node_id)
    |> Enum.map(& &1.from)
    |> Enum.uniq()
    |> Enum.all?(&terminal_node?(Map.get(states, &1)))
  end

  defp terminal_node?(%{status: status}), do: status in @terminal_statuses
  defp terminal_node?(_), do: false

  defp failed_reason(states) do
    states
    |> Enum.find_value(:dag_node_failed, fn {_node_id, state} ->
      if state.status == "failed", do: state.error, else: nil
    end)
  end

  defp all_terminal?(states),
    do:
      states != %{} and
        Enum.all?(states, fn {_id, state} -> state.status in @terminal_statuses end)

  defp fail_fast?(dag) do
    policy = fetch_option(dag.metadata, :failure_policy) || "fail_fast"
    to_string(policy) != "best_effort"
  end

  defp quorum_count(policy, total) do
    count = fetch_option(policy, :count) || fetch_option(policy, :threshold) || total

    cond do
      is_integer(count) -> min(max(count, 1), max(total, 1))
      is_float(count) -> Float.ceil(total * count) |> trunc() |> max(1)
      true -> total
    end
  end

  defp timed_out?(run, started_at) do
    is_integer(run.timeout_ms) and monotonic_ms() - started_at >= run.timeout_ms
  end

  defp default_timeout(dag), do: fetch_option(dag.metadata, :timeout_ms) || @default_timeout_ms

  defp node_max_attempts(options, retry_policy) do
    options
    |> fetch_option(:retry_policy)
    |> case do
      policy when is_map(policy) ->
        fetch_option(policy, :max_attempts) || fetch_option(options, :max_attempts)

      _ ->
        fetch_option(options, :max_attempts)
    end
    |> case do
      nil -> fetch_option(retry_policy, :max_attempts)
      value -> value
    end
    |> positive_integer(1)
  end

  defp fetch_option(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp fetch_option(_map, _key), do: nil

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback
  defp positive_or_nil(value), do: if(is_integer(value) and value > 0, do: value, else: nil)

  defp component_id(module),
    do: AOS.AgentOS.Core.NodeRegistry.component_id_for_module(module) || inspect(module)

  defp collect_results(results) do
    if Enum.any?(results, &match?({:error, _}, &1)),
      do: {:error, results},
      else: {:ok, Enum.map(results, &elem(&1, 1))}
  end

  defp emit(run, event_type, attrs) do
    Harness.trace(
      run.execution_id,
      "orchestration",
      event_type,
      Map.merge(Map.get(attrs, :payload, %{}), %{
        run_id: run.id,
        node_id: Map.get(attrs, :node_id)
      }),
      idempotency_key: "orchestration:#{run.id}:#{event_type}:#{Map.get(attrs, :node_id, "run")}"
    )

    MetaCoordinator.emit(
      EventProtocol.new(event_type, %{
        run_id: run.id,
        execution_id: run.execution_id,
        parent_run_id: run.parent_run_id,
        orchestrator_id: run.orchestrator_id,
        node_id: Map.get(attrs, :node_id),
        idempotency_key: "#{run.id}:#{event_type}:#{Map.get(attrs, :node_id, "run")}",
        payload: json_value(Map.get(attrs, :payload, %{}))
      })
    )

    :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp json_value(nil), do: nil
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  defp json_value(value), do: inspect(value)
end
