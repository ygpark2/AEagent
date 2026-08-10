defmodule AOS.AgentOS.Executions do
  @moduledoc """
  Execution lifecycle helpers shared by the web UI, API, and CLI.
  """
  alias AOS.AgentOS.Autonomy
  alias AOS.AgentOS.Config

  alias AOS.AgentOS.Core.{
    Architect,
    Artifact,
    DelegationTrace,
    Engine,
    Execution,
    Session,
    Workflow
  }

  alias AOS.AgentOS.Evolution.{QualityEvaluator, StrategyEvaluator}
  alias AOS.AgentOS.Harness
  alias AOS.AgentOS.Goals.Processor, as: GoalProcessor
  alias AOS.AgentOS.Orchestration.DAGEngine
  alias AOS.AgentOS.TaskSupervisor

  alias AOS.AgentOS.Execution.{
    ArtifactRecorder,
    CheckpointService,
    HistoryService,
    Notifier,
    Replay,
    Store
  }

  alias AOS.Repo

  def enqueue(task, opts \\ []) when is_binary(task) do
    async? = Keyword.get(opts, :async, true)
    start_immediately? = Keyword.get(opts, :start_immediately, true)
    notify_pid = Keyword.get(opts, :notify)
    initial_context = Keyword.get(opts, :initial_context, %{})
    autonomy_level = Autonomy.normalize_level(Keyword.get(opts, :autonomy_level))
    engine = execution_engine(Keyword.get(opts, :engine))

    with {:ok, session} <-
           resolve_session(task, Keyword.put(opts, :autonomy_level, autonomy_level)),
         history <- HistoryService.effective_history(Keyword.get(opts, :history, []), session.id),
         {:ok, execution} <-
           Store.create_execution(%{
             task: task,
             domain: "general",
             session_id: session.id,
             goal_id: Keyword.get(opts, :goal_id),
             strategy_id: Keyword.get(opts, :strategy_id),
             source_execution_id: Keyword.get(opts, :source_execution_id),
             workflow_id: Keyword.get(opts, :workflow_id),
             trigger_kind: Keyword.get(opts, :trigger_kind, "manual"),
             engine: engine,
             autonomy_level: autonomy_level
           }),
         {:ok, _episode} <-
           Harness.ensure_episode(
             execution,
             Map.put(initial_context, :task, task),
             harness_options(opts)
           ) do
      append_execution_event(execution, "execution.queued", "executions", %{
        "task" => task,
        "trigger_kind" => execution.trigger_kind
      })

      ArtifactRecorder.persist_seed_artifacts(execution, initial_context)

      maybe_start_execution(%{
        execution: execution,
        task: task,
        session: session,
        history: history,
        initial_context: initial_context,
        notify_pid: notify_pid,
        autonomy_level: autonomy_level,
        engine: engine,
        async?: async?,
        start_immediately?: start_immediately?
      })
    end
  end

  def get_execution(id), do: Store.get_execution(id)

  def get_execution!(id), do: Store.get_execution!(id)

  def get_session(id), do: Store.get_session(id)

  def get_session!(id), do: Store.get_session!(id)

  def list_executions(opts \\ []), do: Store.list_executions(opts)

  def list_sessions(opts \\ []), do: Store.list_sessions(opts)

  def session_history(session_id, opts \\ []) do
    HistoryService.session_history(session_id, opts)
  end

  def resume_execution(execution_id, opts \\ []) do
    execution = Store.get_execution!(execution_id)

    allowed_statuses = ~w(queued blocked failed)
    resume_mode = CheckpointService.normalize_resume_mode(Keyword.get(opts, :resume_mode))

    if execution.status in allowed_statuses do
      checkpoint_context =
        CheckpointService.checkpoint_resume_context(
          execution.id,
          Keyword.get(opts, :checkpoint_id),
          resume_mode
        )

      enqueue(execution.task,
        async: Keyword.get(opts, :async, true),
        start_immediately: Keyword.get(opts, :start_immediately, true),
        session_id: execution.session_id,
        source_execution_id: execution.id,
        workflow_id: execution.workflow_id,
        trigger_kind: "resume",
        initial_context: checkpoint_context,
        autonomy_level: execution.autonomy_level,
        engine: execution.engine
      )
    else
      {:error, "execution #{execution_id} is not resumable from status #{execution.status}"}
    end
  end

  def retry_execution(execution_id, opts \\ []) do
    execution = Store.get_execution!(execution_id)

    enqueue(execution.task,
      async: Keyword.get(opts, :async, true),
      start_immediately: Keyword.get(opts, :start_immediately, true),
      session_id: execution.session_id,
      source_execution_id: execution.id,
      workflow_id: execution.workflow_id,
      trigger_kind: "retry",
      autonomy_level: execution.autonomy_level,
      engine: execution.engine
    )
  end

  def replay_execution(execution_id) do
    Replay.replay_execution(execution_id)
  end

  def update_session_metadata(session_id, attrs) when is_map(attrs) do
    Store.update_session_metadata(session_id, attrs)
  end

  def list_artifacts(execution_id), do: Store.list_artifacts(execution_id)

  def get_harness_episode(execution_id), do: Harness.get_episode(execution_id)

  def list_harness_traces(execution_id, opts \\ []) do
    case get_harness_episode(execution_id) do
      nil -> []
      episode -> Harness.list_traces(episode.id, opts)
    end
  end

  def serialize_harness_episode(episode), do: Harness.serialize_episode(episode)
  def serialize_harness_trace(trace), do: Harness.serialize_trace(trace)

  def get_artifact(id), do: Store.get_artifact(id)

  def list_delegation_traces(parent_execution_id),
    do: Store.list_delegation_traces(parent_execution_id)

  def get_dag_run_by_execution(execution_id),
    do: AOS.AgentOS.Orchestration.DAGStore.get_run_by_execution(execution_id)

  def cancel_dag_execution(execution_id) do
    case get_dag_run_by_execution(execution_id) do
      nil -> {:error, :dag_run_not_found}
      run -> DAGEngine.cancel(run.id)
    end
  end

  def list_events(execution_id), do: Store.list_events(execution_id)

  def create_delegation_trace(attrs), do: Store.create_delegation_trace(attrs)

  def update_delegation_trace(id, attrs), do: Store.update_delegation_trace(id, attrs)

  def ensure_execution(%{execution_id: id} = context) when is_binary(id) do
    case get_execution(id) do
      %Execution{} = execution ->
        with {:ok, episode} <- Harness.ensure_episode(execution, context) do
          {:ok, execution, put_harness_context(context, episode)}
        end

      nil ->
        create_and_attach_execution(context)
    end
  end

  def ensure_execution(context), do: create_and_attach_execution(context)

  def mark_running(id, attrs \\ %{}) do
    with {:ok, execution} <-
           Store.update_execution(
             id,
             Map.merge(%{status: "running", started_at: DateTime.utc_now()}, attrs)
           ) do
      update_session_status(execution.session_id, "running", execution.id)
      append_execution_event(execution, "execution.running", "executions", %{})
      Harness.mark_running(execution.id)
      GoalProcessor.handle_execution_started(execution)
      {:ok, execution}
    end
  end

  def complete_execution(id, context) do
    context = QualityEvaluator.maybe_evaluate(context, "succeeded")

    case Harness.verify(context) do
      {:ok, _report, verified_context} -> do_complete_execution(id, verified_context)
      {:error, reason, _report, failed_context} -> fail_execution(id, failed_context, reason)
    end
  end

  defp do_complete_execution(id, context) do
    with {:ok, execution} <-
           Store.update_execution(id, execution_attrs_from_context(context, "succeeded", nil)) do
      update_session_status(execution.session_id, "completed", execution.id)

      append_execution_event(execution, "execution.succeeded", "executions", %{
        "quality_score" => execution.quality_score,
        "fitness_score" => execution.fitness_score
      })

      GoalProcessor.handle_execution_terminal(execution)

      ArtifactRecorder.record_final_artifacts(execution, context)

      StrategyEvaluator.record_outcome(
        execution.strategy_id,
        "succeeded",
        outcome_context(execution, context),
        nil
      )

      Notifier.notify_terminal_event(context, execution)
      Notifier.dispatch_slack_response(execution)
      Harness.finish(execution.id, "succeeded", context)
      {:ok, execution}
    end
  end

  def block_execution(id, context, reason) do
    context = QualityEvaluator.maybe_evaluate(context, "blocked")
    Harness.record_failure(id, reason, context)

    with {:ok, execution} <-
           Store.update_execution(id, execution_attrs_from_context(context, "blocked", reason)) do
      update_session_status(execution.session_id, "blocked", execution.id)

      append_execution_event(execution, "execution.blocked", "executions", %{
        "reason" => reason_to_string(reason)
      })

      GoalProcessor.handle_execution_terminal(execution)

      ArtifactRecorder.record_final_artifacts(execution, context)

      StrategyEvaluator.record_outcome(
        execution.strategy_id,
        "blocked",
        outcome_context(execution, context),
        reason
      )

      Notifier.notify_terminal_event(context, execution)
      Notifier.dispatch_slack_response(execution)
      Harness.finish(execution.id, "blocked", context, reason)
      {:ok, execution}
    end
  end

  def fail_execution(id, context, reason) do
    context = QualityEvaluator.maybe_evaluate(context, "failed")
    Harness.record_failure(id, reason, context)

    with {:ok, execution} <-
           Store.update_execution(id, execution_attrs_from_context(context, "failed", reason)) do
      update_session_status(execution.session_id, "failed", execution.id)

      append_execution_event(execution, "execution.failed", "executions", %{
        "reason" => reason_to_string(reason)
      })

      GoalProcessor.handle_execution_terminal(execution)

      ArtifactRecorder.record_final_artifacts(execution, context)

      StrategyEvaluator.record_outcome(
        execution.strategy_id,
        "failed",
        outcome_context(execution, context),
        reason
      )

      Notifier.notify_terminal_event(context, execution)
      Notifier.dispatch_slack_response(execution)
      Harness.finish(execution.id, "failed", context, reason)
      {:ok, execution}
    end
  end

  def run_existing_execution(execution_id, task, opts \\ []) do
    notify_pid = Keyword.get(opts, :notify)
    graph_builder = Keyword.get(opts, :graph_builder, &Architect.build_graph/2)
    execution = get_execution!(execution_id)

    stored_initial_context =
      CheckpointService.initial_context_for_run(
        execution_id,
        Keyword.get(opts, :initial_context, %{})
      )

    runtime_initial_context = CheckpointService.to_runtime_map(stored_initial_context)

    session_id = Keyword.get(opts, :session_id)

    history =
      opts
      |> Keyword.get(:history, [])
      |> HistoryService.effective_history(session_id, exclude_execution_id: execution_id)
      |> case do
        [] -> HistoryService.restore_history(get_in(runtime_initial_context, [:history]))
        value -> value
      end

    initial_context = runtime_initial_context
    autonomy_level = Autonomy.normalize_level(Keyword.get(opts, :autonomy_level))
    graph = graph_builder.(task, notify: notify_pid)
    workflow = workflow_for_execution(execution)

    dag_definition =
      if execution.engine == "dag", do: workflow_definition(workflow, graph), else: graph

    domain = definition_domain(dag_definition, graph)

    if match?(%AOS.AgentOS.Core.Graph{}, graph),
      do: StrategyEvaluator.mark_used(graph.strategy_id)

    runtime_context =
      Map.merge(initial_context, %{
        task: task,
        history: history,
        execution_id: execution_id,
        source_execution_id: execution.source_execution_id,
        session_id: session_id,
        autonomy_level: autonomy_level,
        strategy_id: graph.strategy_id,
        domain: domain,
        engine: execution.engine || "graph"
      })

    harness_manifest =
      case Harness.manifest_for_execution(execution.id) do
        {:ok, manifest} ->
          manifest

        _ ->
          case Harness.manifest(runtime_context) do
            {:ok, manifest} -> manifest
            _ -> AOS.AgentOS.Harness.Manifest.default()
          end
      end

    runtime_context =
      runtime_context
      |> Map.put(:harness_manifest, harness_manifest)
      |> Map.put_new(:harness_budget_state, AOS.AgentOS.Harness.Budget.initial_state())

    case execution.engine || "graph" do
      "dag" -> DAGEngine.run(dag_definition, runtime_context, dag_options(workflow, notify_pid))
      _ -> Engine.run(graph, runtime_context, notify: notify_pid)
    end
  end

  def record_step_artifact(context, node_id, next_node_id) do
    ArtifactRecorder.record_step_artifact(context, node_id, next_node_id)
  end

  def serialize_execution(%Execution{} = execution) do
    Replay.serialize_execution(execution)
  end

  def serialize_session(%Session{} = session) do
    Replay.serialize_session(session)
  end

  def serialize_artifact(%Artifact{} = artifact) do
    Replay.serialize_artifact(artifact)
  end

  def serialize_delegation_trace(%DelegationTrace{} = trace) do
    Replay.serialize_delegation_trace(trace)
  end

  defp create_and_attach_execution(context) do
    attrs = %{
      task: Map.get(context, :task, "unknown"),
      domain: Map.get(context, :domain, "general"),
      session_id: Map.get(context, :session_id),
      goal_id: Map.get(context, :goal_id),
      autonomy_level: Map.get(context, :autonomy_level, Autonomy.default_level()),
      engine: Map.get(context, :engine, "graph"),
      strategy_id: Map.get(context, :strategy_id),
      workflow_id: Map.get(context, :workflow_id)
    }

    with {:ok, execution} <- Store.create_execution(attrs) do
      updated_context =
        context
        |> Map.put(:execution_id, execution.id)
        |> Map.put_new(:session_id, execution.session_id)

      with {:ok, episode} <- Harness.ensure_episode(execution, updated_context) do
        {:ok, execution, put_harness_context(updated_context, episode)}
      end
    end
  end

  defp resolve_session(task, opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        Store.create_session(
          task,
          Keyword.get(opts, :session_title),
          Keyword.get(opts, :autonomy_level, Autonomy.default_level())
        )

      session_id ->
        fetch_session(session_id)
    end
  end

  defp fetch_session(session_id) do
    case Store.get_session(session_id) do
      nil -> {:error, "session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp update_session_status(session_id, status, execution_id) do
    Store.update_session_status(session_id, status, execution_id)
  end

  defp execution_attrs_from_context(context, status, reason) do
    success = status == "succeeded"
    evolution_attrs = StrategyEvaluator.outcome_attrs(status, context, reason)

    %{
      domain: Map.get(context, :domain, "general") |> to_string(),
      task: Map.get(context, :task, "unknown"),
      status: status,
      autonomy_level: Map.get(context, :autonomy_level, Autonomy.default_level()),
      strategy_id: Map.get(context, :strategy_id),
      fitness_score: evolution_attrs.fitness_score,
      quality_score: Map.get(context, :evaluation_score),
      failure_category: evolution_attrs.failure_category,
      success: success,
      execution_log: %{
        steps:
          Enum.map(
            Map.get(context, :execution_history, []),
            &CheckpointService.serialize_step/1
          )
      },
      final_result: Map.get(context, :result, ""),
      error_message: reason_to_string(reason),
      finished_at: DateTime.utc_now()
    }
  end

  defp reason_to_string(nil), do: nil
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp outcome_context(execution, context) do
    Map.put(
      context,
      :execution_duration_ms,
      duration_ms(execution.started_at, execution.finished_at)
    )
  end

  defp duration_ms(nil, _finished_at), do: 0
  defp duration_ms(_started_at, nil), do: 0

  defp duration_ms(started_at, finished_at) do
    DateTime.diff(finished_at, started_at, :millisecond)
  end

  defp append_execution_event(execution, event_type, source, payload) do
    Store.append_event(%{
      execution_id: execution.id,
      session_id: execution.session_id,
      workflow_id: execution.workflow_id,
      event_type: event_type,
      source: source,
      payload: payload
    })
  end

  defp maybe_start_execution(%{execution: execution, start_immediately?: false}) do
    {:ok, Store.get_execution!(execution.id)}
  end

  defp maybe_start_execution(%{
         execution: execution,
         task: task,
         session: session,
         history: history,
         initial_context: initial_context,
         notify_pid: notify_pid,
         autonomy_level: autonomy_level,
         engine: engine,
         async?: async?,
         start_immediately?: true
       }) do
    runner = fn ->
      run_existing_execution(execution.id, task,
        notify: notify_pid,
        history: history,
        session_id: session.id,
        initial_context: Map.put_new(initial_context, :workflow_id, execution.workflow_id),
        autonomy_level: autonomy_level,
        engine: engine
      )
    end

    run_or_spawn(execution, runner, async?)
  end

  defp run_or_spawn(execution, runner, true) do
    if Config.sync_async_executions?() do
      run_or_spawn(execution, runner, false)
    else
      Task.Supervisor.start_child(TaskSupervisor, runner)
      {:ok, Store.get_execution!(execution.id)}
    end
  end

  defp run_or_spawn(execution, runner, false) do
    runner.()
    {:ok, Store.get_execution!(execution.id)}
  end

  defp execution_engine(nil), do: if(Config.dag_engine_enabled?(), do: "dag", else: "graph")

  defp execution_engine(engine) when engine in [:dag, "dag"],
    do: if(Config.dag_engine_enabled?(), do: "dag", else: "graph")

  defp execution_engine(_engine), do: "graph"

  defp workflow_for_execution(%Execution{workflow_id: nil}), do: nil

  defp workflow_for_execution(%Execution{workflow_id: workflow_id}),
    do: Repo.get(Workflow, workflow_id)

  defp workflow_definition(%Workflow{graph: graph}, _fallback)
       when is_map(graph) and map_size(graph) > 0,
       do: graph

  defp workflow_definition(_workflow, fallback), do: fallback

  defp definition_domain(%{domain: domain}, _fallback) when not is_nil(domain), do: domain
  defp definition_domain(%{"domain" => domain}, _fallback) when not is_nil(domain), do: domain

  defp definition_domain(_definition, graph),
    do: graph.domain || HistoryService.infer_domain(graph)

  defp dag_options(nil, notify_pid), do: [notify: notify_pid]

  defp dag_options(workflow, notify_pid) do
    [notify: notify_pid]
    |> maybe_put_option(:timeout_ms, workflow.timeout_ms)
    |> maybe_put_option(:retry_policy, workflow.retry_policy)
    |> maybe_put_option(:metadata, workflow.metadata)
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp harness_options(opts),
    do: Keyword.take(opts, [:manifest_path, :harness_manifest, :success_criteria, :constraints])

  defp put_harness_context(context, nil), do: context

  defp put_harness_context(context, episode) do
    context
    |> Map.put_new(:harness_manifest, episode.manifest)
    |> Map.put_new(:harness_budget_state, AOS.AgentOS.Harness.Budget.initial_state())
  end
end
