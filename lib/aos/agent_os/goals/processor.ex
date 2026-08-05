defmodule AOS.AgentOS.Goals.Processor do
  @moduledoc "Processes Goal events and reconciles GoalRun lifecycle."
  use GenServer
  import Ecto.Query
  require Logger

  alias AOS.AgentOS.Core.{Execution, Goal, GoalEvent, GoalRun}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Goals
  alias AOS.AgentOS.Goals.Verifier
  alias AOS.Repo

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def dispatch(event_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:process, event_id, opts})
  end

  def process(event_id, opts \\ []) do
    with {:ok, event} <- claim_event(event_id) do
      case get_goal(event.goal_id) do
        {:ok, goal} ->
          process_claimed_event(event, goal, opts)

        {:error, :goal_not_active} ->
          mark_event(event, "ignored", "goal is not active")
          {:ok, :ignored}

        {:error, reason} ->
          handle_processing_error(event_id, reason, {:error, reason})
      end
    else
      {:error, :already_processed} = result -> result
      {:error, reason} = result -> handle_processing_error(event_id, reason, result)
    end
  end

  def handle_execution_started(%Execution{goal_id: nil}), do: :ok

  def handle_execution_started(%Execution{goal_id: goal_id} = execution) do
    case Repo.get_by(GoalRun, execution_id: execution.id) do
      %GoalRun{status: "queued"} = run ->
        run
        |> GoalRun.changeset(%{status: "running", started_at: DateTime.utc_now()})
        |> Repo.update()
        |> case do
          {:ok, _run} -> :ok
          {:error, reason} -> {:error, reason}
        end

      %GoalRun{goal_id: ^goal_id} ->
        :ok

      nil ->
        :ok
    end
  end

  def handle_execution_terminal(%Execution{goal_id: nil}), do: :ok

  def handle_execution_terminal(%Execution{goal_id: goal_id} = execution) do
    with %Goal{} = goal <- Repo.get(Goal, goal_id),
         %GoalRun{} = run <- Repo.get_by(GoalRun, execution_id: execution.id),
         verification <- Verifier.verify(goal, execution),
         run_status <- terminal_run_status(execution.status, verification),
         {:ok, _run} <- update_run(run, run_status, verification, execution),
         {:ok, _event} <- mark_event_by_run(run) do
      reconcile_goal(goal, run, run_status, verification)
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:process, event_id, opts}, state) do
    case process(event_id, opts) do
      {:error, reason} ->
        Logger.error("[GoalProcessor] Event #{event_id} failed: #{inspect(reason)}")

      _result ->
        :ok
    end

    {:noreply, state}
  end

  defp claim_event(event_id) do
    query = from e in GoalEvent, where: e.id == ^event_id and e.status == "queued"

    case Repo.update_all(query, set: [status: "processing"]) do
      {1, _} -> {:ok, Repo.get!(GoalEvent, event_id)}
      _ -> {:error, :already_processed}
    end
  end

  defp get_goal(goal_id) do
    case Repo.get(Goal, goal_id) do
      %Goal{} = goal ->
        if Goals.eligible_status?(goal.status), do: {:ok, goal}, else: {:error, :goal_not_active}

      nil ->
        {:error, :goal_not_found}
    end
  end

  defp process_claimed_event(event, goal, opts) do
    with {:ok, run} <- create_run(goal, event),
         {:ok, execution} <- enqueue_execution(goal, event, run, opts),
         {:ok, run} <- link_execution(run, execution),
         {:ok, _event} <- mark_event(event, "dispatched", nil) do
      if execution.status in ["succeeded", "failed", "blocked"],
        do: handle_execution_terminal(execution)

      {:ok, run}
    else
      {:error, reason} -> handle_processing_error(event.id, reason, {:error, reason})
    end
  end

  defp create_run(goal, event) do
    attempt =
      GoalRun
      |> where([r], r.goal_id == ^goal.id)
      |> select([r], max(r.attempt))
      |> Repo.one()
      |> case do
        nil -> 1
        value -> value + 1
      end

    %GoalRun{}
    |> GoalRun.changeset(%{
      goal_id: goal.id,
      event_id: event.id,
      attempt: attempt,
      status: "queued",
      metadata: %{"event_type" => event.event_type, "source" => event.source}
    })
    |> Repo.insert()
  end

  defp enqueue_execution(goal, event, run, opts) do
    task = build_task(goal, event)

    initial_context = %{
      goal_id: goal.id,
      goal_event_id: event.id,
      goal_run_id: run.id,
      goal_name: goal.name,
      goal_objective: goal.objective,
      goal_success_criteria: goal.success_criteria,
      goal_constraints: goal.constraints,
      goal_context: goal.context,
      goal_event: %{
        type: event.event_type,
        source: event.source,
        payload: event.payload
      }
    }

    Executions.enqueue(task,
      async: Keyword.get(opts, :execution_async, true),
      start_immediately: Keyword.get(opts, :start_immediately, true),
      session_id: Keyword.get(opts, :session_id),
      initial_context: initial_context,
      goal_id: goal.id,
      trigger_kind: "goal:#{event.event_type}",
      autonomy_level: goal.autonomy_level,
      session_title: "Goal: #{goal.name}"
    )
  end

  defp link_execution(run, execution) do
    run
    |> GoalRun.changeset(%{execution_id: execution.id})
    |> Repo.update()
  end

  defp mark_event(event, status, error_message) do
    event
    |> GoalEvent.changeset(%{
      status: status,
      processed_at: DateTime.utc_now(),
      error_message: error_message
    })
    |> Repo.update()
  end

  defp mark_event_by_run(run) do
    case Repo.get(GoalEvent, run.event_id) do
      %GoalEvent{} = event -> mark_event(event, "dispatched", nil)
      nil -> :ok
    end
  end

  defp handle_processing_error(event_id, reason, result) do
    case Repo.get(GoalEvent, event_id) do
      %GoalEvent{} = event -> mark_event(event, "failed", inspect(reason))
      nil -> :ok
    end

    result
  end

  defp update_run(run, status, verification, execution) do
    attrs = %{
      status: status,
      verification_result: verification,
      finished_at: DateTime.utc_now(),
      error_message:
        if(verification.passed, do: nil, else: get_in(verification, [:details, :reason]))
    }

    attrs =
      if status in ["running", "succeeded", "failed", "blocked"],
        do: Map.put(attrs, :started_at, run.started_at || execution.started_at),
        else: attrs

    run
    |> GoalRun.changeset(attrs)
    |> Repo.update()
  end

  defp reconcile_goal(goal, run, run_status, verification) do
    attrs = %{
      last_run_at: DateTime.utc_now(),
      last_error:
        if(verification.passed, do: nil, else: get_in(verification, [:details, :reason]))
    }

    attrs =
      case run_status do
        "succeeded" when goal.goal_type == "one_shot" ->
          Map.merge(attrs, %{status: "succeeded", completed_at: DateTime.utc_now()})

        "succeeded" ->
          Map.merge(attrs, %{status: "active", completed_at: nil})

        "blocked" ->
          Map.put(attrs, :status, "waiting")

        "failed" ->
          Map.put(attrs, :status, "failed")

        _ ->
          attrs
      end

    with {:ok, updated_goal} <- Goals.update_goal(goal.id, attrs) do
      maybe_schedule_retry(updated_goal, run, run_status, verification)
    end
  end

  defp maybe_schedule_retry(goal, run, "failed", verification) do
    max_attempts = retry_max_attempts(goal.retry_policy)

    if max_attempts && run.attempt < max_attempts do
      with {:ok, active_goal} <-
             Goals.update_goal(goal.id, %{status: "active", completed_at: nil}),
           {:ok, _event} <-
             Goals.trigger(
               active_goal.id,
               "retry",
               %{
                 "source_run_id" => run.id,
                 "failed_attempt" => run.attempt,
                 "reason" => get_in(verification, [:details, :reason])
               },
               source: "goal_processor",
               idempotency_key: "retry:#{run.id}",
               async: true
             ) do
        {:ok, active_goal}
      end
    else
      {:ok, goal}
    end
  end

  defp maybe_schedule_retry(goal, _run, _run_status, _verification), do: {:ok, goal}

  defp retry_max_attempts(policy) when is_map(policy) do
    value = Map.get(policy, "max_attempts") || Map.get(policy, :max_attempts)

    case value do
      value when is_integer(value) and value > 1 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {attempts, ""} when attempts > 1 -> attempts
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp retry_max_attempts(_policy), do: nil

  defp terminal_run_status("succeeded", %{passed: true}), do: "succeeded"
  defp terminal_run_status("succeeded", _verification), do: "failed"
  defp terminal_run_status("blocked", _verification), do: "blocked"
  defp terminal_run_status("failed", _verification), do: "failed"
  defp terminal_run_status(status, _verification), do: status

  defp build_task(goal, event) do
    """
    Advance the following goal.

    Goal name: #{goal.name}
    Objective: #{goal.objective}
    Event type: #{event.event_type}
    Event source: #{event.source}
    Event payload: #{safe_encode(event.payload)}
    Success criteria: #{safe_encode(goal.success_criteria)}
    Constraints: #{safe_encode(goal.constraints)}
    Required outcome: perform the work, verify the result, and report what remains.
    """
    |> String.trim()
  end

  defp safe_encode(value) do
    Jason.encode!(value)
  rescue
    _ -> inspect(value)
  end
end
