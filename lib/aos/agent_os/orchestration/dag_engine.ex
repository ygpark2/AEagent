defmodule AOS.AgentOS.Orchestration.DAGEngine do
  @moduledoc "Durable fan-out/fan-in DAG execution engine."

  alias AOS.AgentOS.Core.{DAGRun, Graph, PolicyGate}
  alias AOS.AgentOS.Execution.{ArtifactRecorder, ResumeContext}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Harness
  alias AOS.AgentOS.ToolUse.{ApprovalQueue, ApprovalRequest}
  alias AOS.Repo
  import Ecto.Query

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

        %DAGRun{status: status} = run when status in ~w(queued running suspended) ->
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

      %DAGRun{status: status} = run when status in ~w(queued running) ->
        {:error, {:dag_already_running, run.id, status}}

      %DAGRun{} = run ->
        with {:ok, dag} <- DAGDefinition.normalize(run.definition) do
          approval_context = resolve_approval_context(run, opts)

          context =
            run.base_context
            |> restore_context()
            |> Map.put(:execution_id, run.execution_id)
            |> Map.merge(approval_context)

          Executions.mark_running(run.execution_id)
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

      %{status: status} = run when status in ~w(queued running suspended) ->
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
             base_context: persistable_context(context),
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
      contexts = initial_resumed_contexts(states)
      history = initial_resumed_history(states, Map.get(context, :execution_history, []))
      orchestrate(dag, context, run, states, contexts, history, monotonic_ms(), opts)
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

          cond do
            suspended_state =
                Enum.find(next_states, fn {_id, state} -> state.status == "suspended" end) ->
              {_suspended_node_id, suspended_node} = suspended_state

              finish_suspended(
                run,
                base_context,
                next_contexts,
                next_history,
                suspended_node.error
              )

            fail_fast?(dag) and
                Enum.any?(next_states, fn {_id, state} -> state.status == "failed" end) ->
              finish_failed(
                run,
                base_context,
                next_states,
                next_contexts,
                next_history,
                failed_reason(next_states)
              )

            true ->
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
          case reason do
            {:approval_required, _} ->
              step = step_record(node_id, :approval_required, failed_context)
              next_history = history_acc ++ [step]
              node_context = Map.put(failed_context, :execution_history, next_history)

              DAGStore.update_node(state.record, %{
                status: "suspended",
                outcome: "approval_required",
                attempt: attempt,
                output: node_output(node_context),
                error_message: inspect(reason),
                finished_at: DateTime.utc_now()
              })

              ArtifactRecorder.record_step_artifact(node_context, node_id, nil)

              emit(run, "node.suspended", %{
                node_id: node_id,
                payload: %{reason: inspect(reason), attempt: attempt}
              })

              {
                Map.put(state_acc, node_id, %{
                  state
                  | status: "suspended",
                    outcome: "approval_required",
                    context: node_context,
                    attempt: attempt,
                    error: reason
                }),
                Map.put(context_acc, node_id, node_context),
                next_history
              }

            _ ->
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
          end

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
    case reason do
      {:approval_required, _} ->
        finish_suspended(run, base_context, contexts, history, reason)

      _ ->
        if PolicyGate.blocking_reason?(reason) do
          finish_blocked(run, base_context, contexts, history, reason)
        else
          finish_failed_run(run, base_context, contexts, history, reason)
        end
    end
  end

  defp finish_suspended(run, base_context, contexts, history, reason) do
    final_context = final_context(base_context, contexts, history)

    case reason do
      {:approval_required, request} ->
        ensure_approval_request(run, final_context, request)

      _ ->
        :ok
    end

    DAGStore.update_run(run.id, %{
      status: "suspended",
      base_context: persistable_context(final_context),
      result: node_output(final_context),
      error_message: inspect(reason),
      heartbeat_at: DateTime.utc_now()
    })

    emit(run, "orchestration.suspended", %{
      payload: %{status: "suspended", reason: inspect(reason)}
    })

    Executions.suspend_execution(run.execution_id, final_context, reason)
    {:error, :dag, reason, final_context}
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
         error: nil,
         context: %{}
       }}
    end)
  end

  defp recoverable_status(status) when status in ["ready", "running", "suspended"], do: "pending"
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
    history_order =
      history
      |> Enum.map(fn
        %{node_id: id} -> to_string(id)
        %{"node_id" => id} -> to_string(id)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    predecessors =
      DAGDefinition.predecessors(dag, node_id)
      |> Enum.map(& &1.from)
      |> Enum.uniq()
      |> Enum.sort_by(fn pred ->
        case Enum.find_index(history_order, &(&1 == to_string(pred))) do
          nil -> {1, to_string(pred)}
          idx -> {0, idx}
        end
      end)

    predecessor_entries =
      Enum.map(predecessors, fn pred ->
        ctx = Map.get(contexts, pred) || Map.get(contexts, to_string(pred))
        {pred, ctx}
      end)
      |> Enum.reject(fn {_pred, ctx} -> is_nil(ctx) or ctx == %{} end)

    inherited = merge_predecessor_contexts(base_context, predecessor_entries)

    inputs =
      Map.new(predecessors, fn predecessor ->
        predecessor_context =
          Map.get(contexts, predecessor) ||
            Map.get(contexts, to_string(predecessor), %{})

        {to_string(predecessor), node_output(predecessor_context)}
      end)

    inherited
    |> Map.put(:dag_run_id, run.id)
    |> Map.put(:dag_node_id, node_id)
    |> Map.put(:graph_nodes, dag.nodes)
    |> Map.put(:execution_history, history)
    |> Map.put(:dag_inputs, inputs)
    |> Map.put(:inputs, inputs)
    |> maybe_put_dag_result(inputs)
  end

  defp maybe_put_dag_result(context, inputs) when map_size(inputs) <= 1, do: context

  defp maybe_put_dag_result(context, inputs) do
    results =
      Enum.filter(inputs, fn {_node_id, output} ->
        Map.has_key?(output, "result") or Map.has_key?(output, :result)
      end)

    if results == [] do
      context
    else
      rendered =
        results
        |> Enum.map_join("\n\n", fn {node_id, output} ->
          val = Map.get(output, "result", Map.get(output, :result))
          "[#{node_id}]\n#{inspect(val)}"
        end)

      Map.put(context, :result, rendered)
    end
  end

  defp merge_predecessor_contexts(base_context, predecessor_entries) do
    case predecessor_entries do
      [] ->
        base_context

      [{pred_id, pred_ctx}] ->
        merge_single_predecessor(base_context, pred_id, pred_ctx)

      _multiple ->
        merge_parallel_predecessors(base_context, predecessor_entries)
    end
  end

  defp merge_single_predecessor(base_context, pred_id, pred_ctx) do
    existing_node_outputs = get_node_outputs(base_context)
    inherited_node_outputs = get_node_outputs(pred_ctx)

    node_outputs =
      existing_node_outputs
      |> Map.merge(inherited_node_outputs)
      |> Map.put(to_string(pred_id), pred_ctx)

    artifacts =
      (extract_artifacts(base_context) ++ extract_artifacts(pred_ctx))
      |> Enum.uniq()

    merged =
      base_context
      |> Map.merge(pred_ctx)
      |> maybe_put_artifacts(artifacts, [base_context, pred_ctx])
      |> Map.put(:node_outputs, node_outputs)

    merged
  end

  defp merge_parallel_predecessors(base_context, predecessor_entries) do
    contexts_list = Enum.map(predecessor_entries, &elem(&1, 1))

    existing_node_outputs =
      [base_context | contexts_list]
      |> Enum.reduce(%{}, fn ctx, acc -> Map.merge(acc, get_node_outputs(ctx)) end)

    node_outputs =
      Enum.reduce(predecessor_entries, existing_node_outputs, fn {pred_id, pred_ctx}, acc ->
        Map.put(acc, to_string(pred_id), pred_ctx)
      end)

    artifacts =
      [base_context | contexts_list]
      |> Enum.flat_map(&extract_artifacts/1)
      |> Enum.uniq()

    accumulated = Enum.reduce(contexts_list, %{}, &merge_contexts/2)

    base_context
    |> merge_contexts(accumulated)
    |> Map.put(:node_outputs, node_outputs)
    |> Map.put(:artifacts, artifacts)
  end

  defp get_node_outputs(context) when is_map(context) do
    case Map.get(context, :node_outputs) || Map.get(context, "node_outputs") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp get_node_outputs(_), do: %{}

  defp maybe_put_artifacts(merged, artifacts, contexts_to_check) do
    should_put? =
      artifacts != [] or
        Enum.any?(contexts_to_check, fn ctx ->
          is_map(ctx) and (Map.has_key?(ctx, :artifacts) or Map.has_key?(ctx, "artifacts"))
        end)

    if should_put?, do: Map.put(merged, :artifacts, artifacts), else: merged
  end

  defp merge_contexts(ctx1, ctx2) when is_map(ctx1) and is_map(ctx2) do
    Map.merge(ctx1, ctx2, fn
      key, v1, v2 when key in [:artifacts, "artifacts"] ->
        (List.wrap(v1) ++ List.wrap(v2)) |> Enum.uniq()

      key, v1, v2 when key in [:node_outputs, "node_outputs"] and is_map(v1) and is_map(v2) ->
        Map.merge(v1, v2)

      _key, v1, v2 when is_list(v1) and is_list(v2) ->
        Enum.uniq(v1 ++ v2)

      _key, v1, v2 when is_map(v1) and is_map(v2) and not is_struct(v1) and not is_struct(v2) ->
        merge_contexts(v1, v2)

      _key, _v1, v2 ->
        v2
    end)
  end

  defp merge_contexts(ctx1, _ctx2) when is_map(ctx1), do: ctx1
  defp merge_contexts(_ctx1, ctx2) when is_map(ctx2), do: ctx2
  defp merge_contexts(ctx1, _ctx2), do: ctx1

  defp extract_artifacts(context) when is_map(context) do
    artifacts =
      case Map.get(context, :artifacts) do
        nil -> Map.get(context, "artifacts")
        val -> val
      end

    case artifacts do
      nil -> []
      list when is_list(list) -> list
      single -> [single]
    end
  end

  defp extract_artifacts(_), do: []

  defp final_context(base_context, contexts, history) do
    all_contexts = build_all_contexts(contexts, history)

    last_context =
      all_contexts
      |> Enum.reverse()
      |> Enum.find(&(Map.has_key?(&1, :result) or Map.has_key?(&1, "result"))) || %{}

    all_artifacts =
      [base_context | all_contexts]
      |> Enum.flat_map(&extract_artifacts/1)
      |> Enum.uniq()

    all_node_outputs = extract_all_node_outputs(base_context, contexts, all_contexts)

    accumulated = Enum.reduce(all_contexts, %{}, &merge_contexts/2)

    base_context
    |> merge_contexts(accumulated)
    |> Map.merge(last_context)
    |> Map.put(:execution_history, history)
    |> maybe_put_node_outputs(all_node_outputs)
    |> maybe_put_artifacts(all_artifacts, [base_context | all_contexts])
  end

  defp build_all_contexts(contexts, history) do
    ordered_node_ids =
      history
      |> Enum.map(fn
        %{node_id: id} -> to_string(id)
        %{"node_id" => id} -> to_string(id)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ordered_contexts =
      Enum.map(ordered_node_ids, fn id ->
        Map.get(contexts, id) ||
          try_existing_atom(id, fn atom -> Map.get(contexts, atom) end)
      end)
      |> Enum.reject(&is_nil/1)

    if ordered_contexts != [] do
      remaining =
        contexts
        |> Enum.reject(fn {k, _v} -> to_string(k) in ordered_node_ids end)
        |> Enum.map(&elem(&1, 1))

      ordered_contexts ++ remaining
    else
      Map.values(contexts)
    end
  end

  defp extract_all_node_outputs(base_context, contexts, all_contexts) do
    existing =
      [base_context | all_contexts]
      |> Enum.reduce(%{}, fn ctx, acc -> Map.merge(acc, get_node_outputs(ctx)) end)

    Enum.reduce(contexts, existing, fn {node_id, ctx}, acc ->
      if is_nil(ctx) or ctx == %{} do
        acc
      else
        Map.put(acc, to_string(node_id), ctx)
      end
    end)
  end

  defp maybe_put_node_outputs(context, node_outputs) do
    if node_outputs != %{}, do: Map.put(context, :node_outputs, node_outputs), else: context
  end

  defp try_existing_atom(binary, fun) when is_binary(binary) do
    atom = String.to_existing_atom(binary)
    fun.(atom)
  rescue
    ArgumentError -> nil
  end

  defp terminal_context(context, run) do
    context
    |> Map.put(:execution_id, run.execution_id)
    |> Map.put(:execution_history, [])
    |> Map.put(:result, get_in(run.result || %{}, ["result"]) || Map.get(context, :result))
  end

  def persistable_context(%ResumeContext{} = context) do
    context |> ResumeContext.to_map() |> persistable_context()
  end

  def persistable_context(context) when is_map(context) do
    Enum.reduce(context, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), json_value(value))
    end)
  end

  def persistable_context(other), do: other

  def restore_context(context) when is_map(context) do
    Enum.reduce(context, %{}, fn {key, value}, acc ->
      atom_key = atomize_key(key)

      restored_value =
        cond do
          atom_key == :execution_history or key == "execution_history" ->
            restore_execution_history(value)

          (atom_key == :node_outputs or key == "node_outputs") and is_map(value) ->
            restore_node_outputs(value)

          atom_key == :artifacts or key == "artifacts" ->
            restore_artifacts(value)

          (atom_key == :inputs or key == "inputs") and is_map(value) ->
            restore_node_outputs(value)

          true ->
            value
        end

      acc
      |> Map.put(key, restored_value)
      |> Map.put(atom_key, restored_value)
    end)
  end

  def restore_context(context), do: context

  defp restore_node_outputs(node_outputs) when is_map(node_outputs) do
    Enum.reduce(node_outputs, %{}, fn {node_id, output}, acc ->
      restored_output = restore_output_map(output)
      atom_id = atomize_key(node_id)

      acc
      |> Map.put(to_string(node_id), restored_output)
      |> Map.put(atom_id, restored_output)
    end)
  end

  defp restore_node_outputs(other), do: other

  defp restore_output_map(output) when is_map(output) and not is_struct(output) do
    Enum.reduce(output, %{}, fn {k, v}, acc ->
      atom_k = atomize_key(k)

      restored_v =
        if atom_k == :artifacts or k == "artifacts",
          do: restore_artifacts(v),
          else: v

      acc
      |> Map.put(k, restored_v)
      |> Map.put(atom_k, restored_v)
    end)
  end

  defp restore_output_map(output), do: output

  defp restore_artifacts(artifacts) when is_list(artifacts) do
    Enum.map(artifacts, &restore_artifact/1)
  end

  defp restore_artifacts(artifact) when is_map(artifact) do
    restore_artifact(artifact)
  end

  defp restore_artifacts(other), do: other

  defp restore_artifact(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      atom_k = atomize_key(k)

      restored_v =
        if is_map(v) and not is_struct(v) and k in ["payload", :payload, "metadata", :metadata] do
          restore_artifact(v)
        else
          v
        end

      acc
      |> Map.put(k, restored_v)
      |> Map.put(atom_k, restored_v)
    end)
  end

  defp restore_artifact(other), do: other

  defp atomize_key(k) when is_atom(k), do: k

  defp atomize_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp atomize_key(k), do: k

  defp restore_execution_history(history) when is_list(history) do
    Enum.map(history, fn
      %{} = step ->
        node_id = Map.get(step, :node_id, Map.get(step, "node_id"))
        outcome = Map.get(step, :outcome, Map.get(step, "outcome"))
        feedback = Map.get(step, :feedback, Map.get(step, "feedback"))
        timestamp = Map.get(step, :timestamp, Map.get(step, "timestamp"))

        %{
          :node_id => node_id,
          "node_id" => node_id,
          :outcome => outcome,
          "outcome" => outcome,
          :feedback => feedback,
          "feedback" => feedback,
          :timestamp => timestamp,
          "timestamp" => timestamp
        }

      other ->
        other
    end)
  end

  defp restore_execution_history(other), do: other

  defp step_record(node_id, outcome, context) do
    %{
      node_id: node_id,
      outcome: outcome,
      feedback: Map.get(context, :feedback, Map.get(context, "feedback")),
      timestamp: DateTime.utc_now()
    }
  end

  defp node_output(context) do
    standard =
      %{
        "result" => json_value(Map.get(context, :result, Map.get(context, "result"))),
        "last_outcome" =>
          json_value(Map.get(context, :last_outcome, Map.get(context, "last_outcome"))),
        "feedback" => json_value(Map.get(context, :feedback, Map.get(context, "feedback"))),
        "evaluation_score" =>
          json_value(Map.get(context, :evaluation_score, Map.get(context, "evaluation_score"))),
        "evaluation_feedback" =>
          json_value(
            Map.get(context, :evaluation_feedback, Map.get(context, "evaluation_feedback"))
          )
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    system_keys = ~w(
      harness_manifest harness_budget_state graph_nodes dag_nodes dag_run_id
      dag_node_id execution_history dag_inputs inputs node_outputs notify task session_id
      execution_id workflow_id strategy_id engine domain autonomy_level
    )

    custom =
      context
      |> Enum.reject(fn {k, _v} ->
        str = to_string(k)
        str in system_keys or String.starts_with?(str, "harness_")
      end)
      |> Enum.map(fn {k, v} -> {to_string(k), json_value(v)} end)
      |> Map.new()

    Map.merge(custom, standard)
  end

  defp resolve_approval_context(run, opts) do
    explicit =
      Keyword.get(opts, :approval_request) ||
        Keyword.get(opts, :approved_request) ||
        Keyword.get(opts, :approval)

    latest =
      cond do
        explicit ->
          explicit

        run.execution_id ->
          ApprovalRequest
          |> where([r], r.execution_id == ^run.execution_id and r.status == "approved")
          |> order_by([r], desc: r.decided_at, desc: r.inserted_at)
          |> limit(1)
          |> Repo.one()

        true ->
          nil
      end

    case latest do
      %ApprovalRequest{} = req ->
        serialized = ApprovalQueue.serialize(req)

        %{
          approval_request: serialized,
          approved_request: serialized,
          last_approval: serialized,
          approval_decision: %{
            "status" => "approved",
            "decided_by" => req.decided_by,
            "decision_reason" => req.decision_reason,
            "tool_name" => req.tool_name,
            "arguments" => req.arguments
          }
        }

      req_map when is_map(req_map) ->
        %{
          approval_request: req_map,
          approved_request: req_map,
          last_approval: req_map,
          approval_decision: Map.get(req_map, :decision, req_map)
        }

      _ ->
        %{}
    end
  end

  defp ensure_approval_request(_run, _context, %ApprovalRequest{}), do: :ok

  defp ensure_approval_request(run, context, request) when is_map(request) do
    id = Map.get(request, :id) || Map.get(request, "id")

    if is_nil(id) or is_nil(ApprovalQueue.get_request(id)) do
      attrs = %{
        execution_id: run.execution_id,
        session_id: Map.get(context, :session_id),
        workflow_id: run.workflow_id,
        server_id: Map.get(request, :server_id) || Map.get(request, "server_id", "internal"),
        tool_name: Map.get(request, :tool_name) || Map.get(request, "tool_name", "approval_gate"),
        arguments: Map.get(request, :arguments) || Map.get(request, "arguments", %{}),
        risk_tier: Map.get(request, :risk_tier) || Map.get(request, "risk_tier", "high"),
        requested_by: "policy_gate"
      }

      ApprovalQueue.create_request(attrs)
    else
      :ok
    end
  end

  defp ensure_approval_request(_run, _context, _request), do: :ok

  defp initial_resumed_contexts(states) do
    states
    |> Enum.filter(fn {_id, state} -> state.record.status == "succeeded" end)
    |> Map.new(fn {node_id, state} ->
      out = state.record.output || %{}

      custom_ctx =
        Enum.reduce(out, %{}, fn {k, v}, acc ->
          atom_key =
            try do
              String.to_existing_atom(k)
            rescue
              _ -> k
            end

          acc
          |> Map.put(k, v)
          |> Map.put(atom_key, v)
        end)

      standard_ctx =
        %{
          result: Map.get(out, "result"),
          last_outcome: parse_outcome(Map.get(out, "last_outcome")),
          feedback: Map.get(out, "feedback"),
          evaluation_score: Map.get(out, "evaluation_score"),
          evaluation_feedback: Map.get(out, "evaluation_feedback")
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      ctx = Map.merge(custom_ctx, standard_ctx)

      {node_id, ctx}
    end)
  end

  defp initial_resumed_history(states, existing_history) do
    if existing_history != [] do
      existing_history
    else
      states
      |> Map.values()
      |> Enum.filter(&(&1.record.status == "succeeded"))
      |> Enum.sort_by(& &1.record.inserted_at, DateTime)
      |> Enum.map(fn state ->
        step_record(
          state.record.node_id,
          parse_outcome(state.record.outcome),
          state.record.output || %{}
        )
      end)
    end
  end

  defp parse_outcome(nil), do: :success
  defp parse_outcome(val) when is_atom(val), do: val

  defp parse_outcome(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> val
  end

  defp parse_outcome(val), do: val

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
  defp json_value(value) when is_atom(value), do: to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(%ResumeContext{} = value),
    do: value |> ResumeContext.to_map() |> json_value()

  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  defp json_value(value), do: inspect(value)
end
