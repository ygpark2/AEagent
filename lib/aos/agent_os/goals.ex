defmodule AOS.AgentOS.Goals do
  @moduledoc """
  Public API for durable, event-driven goals.

  A Goal describes an outcome. Each event creates at most one GoalRun, and a
  GoalRun is linked to one existing AgentOS execution.
  """

  import Ecto.Query

  alias AOS.AgentOS.Autonomy
  alias AOS.AgentOS.Core.{Goal, GoalEvent, GoalRun}
  alias AOS.AgentOS.Goals.{Processor, StateMachine}
  alias AOS.Repo

  @default_limit 50
  @goal_attrs ~w(
    name objective description status goal_type trigger success_criteria constraints
    policy_profile retry_policy output_config context metadata autonomy_level owner version
    next_run_at last_run_at completed_at last_error
  )

  @eligible_statuses ~w(active waiting blocked failed)

  def create_goal(attrs) when is_map(attrs) do
    attrs = normalize_goal_attrs(attrs, :create)

    %Goal{}
    |> Goal.changeset(attrs)
    |> Repo.insert()
  end

  def update_goal(id_or_name, attrs) when is_map(attrs) do
    with {:ok, goal} <- fetch_goal(id_or_name),
         attrs <- normalize_goal_attrs(attrs, :update),
         :ok <- validate_status_change(goal, Map.get(attrs, :status)) do
      attrs = Map.put(attrs, :version, goal.version + 1)

      goal
      |> Goal.changeset(attrs)
      |> Repo.update()
    end
  end

  def get_goal(id_or_name), do: resolve_goal(id_or_name)

  def get_goal!(id_or_name) do
    case resolve_goal(id_or_name) do
      %Goal{} = goal -> goal
      nil -> raise Ecto.NoResultsError, queryable: Goal
    end
  end

  def list_goals(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    status = Keyword.get(opts, :status)
    owner = Keyword.get(opts, :owner)

    Goal
    |> maybe_filter(:status, status)
    |> maybe_filter(:owner, owner)
    |> order_by([g], desc: g.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def pause_goal(id_or_name), do: change_status(id_or_name, "paused")
  def resume_goal(id_or_name), do: change_status(id_or_name, "active", resume_attrs(id_or_name))
  def cancel_goal(id_or_name), do: change_status(id_or_name, "cancelled")

  def list_events(goal_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    GoalEvent
    |> where([e], e.goal_id == ^goal_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_event(id), do: Repo.get(GoalEvent, id)

  def list_runs(goal_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    GoalRun
    |> where([r], r.goal_id == ^goal_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_run(id), do: Repo.get(GoalRun, id)

  @doc """
  Records a Goal event and schedules one bounded run for it.

  `async: false` is useful for callers that need the complete run result. In
  production the default is asynchronous processing.
  """
  def trigger(goal_id_or_name, event_type, payload \\ %{}, opts \\ [])

  def trigger(goal_id_or_name, event_type, payload, opts)
      when is_binary(event_type) and is_map(payload) do
    with {:ok, goal} <- fetch_goal(goal_id_or_name),
         {:ok, event, created?} <- create_or_get_event(goal, event_type, payload, opts) do
      if created? or event.status == "queued" do
        dispatch_event(event.id, opts)
      end

      {:ok, Repo.get!(GoalEvent, event.id)}
    end
  end

  def trigger(_goal_id_or_name, _event_type, _payload, _opts),
    do: {:error, "goal event payload must be a map"}

  @doc "Dispatches all due interval goals using an atomic database claim."
  def dispatch_due_goals(now \\ DateTime.utc_now(), opts \\ []) do
    due_goals =
      Goal
      |> where([g], g.status == "active")
      |> where([g], not is_nil(g.next_run_at) and g.next_run_at <= ^now)
      |> Repo.all()

    Enum.reduce(due_goals, %{dispatched: 0, skipped: 0}, fn goal, acc ->
      case claim_due_goal(goal, now) do
        {:ok, slot} ->
          event_payload = %{
            "scheduled_for" => DateTime.to_iso8601(slot),
            "goal_name" => goal.name
          }

          case trigger(goal.id, "schedule", event_payload,
                 source: Keyword.get(opts, :source, "scheduler"),
                 idempotency_key: "schedule:#{goal.id}:#{DateTime.to_iso8601(slot)}",
                 async: Keyword.get(opts, :async, true),
                 execution_async: Keyword.get(opts, :execution_async, true),
                 start_immediately: Keyword.get(opts, :start_immediately, true)
               ) do
            {:ok, _event} -> %{acc | dispatched: acc.dispatched + 1}
            {:error, _reason} -> %{acc | skipped: acc.skipped + 1}
          end

        :not_claimed ->
          %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  def serialize_goal(%Goal{} = goal) do
    %{
      id: goal.id,
      name: goal.name,
      objective: goal.objective,
      description: goal.description,
      status: goal.status,
      goal_type: goal.goal_type,
      trigger: goal.trigger,
      success_criteria: goal.success_criteria,
      constraints: goal.constraints,
      policy_profile: goal.policy_profile,
      retry_policy: goal.retry_policy,
      output_config: goal.output_config,
      context: goal.context,
      metadata: goal.metadata,
      autonomy_level: goal.autonomy_level,
      owner: goal.owner,
      version: goal.version,
      next_run_at: goal.next_run_at,
      last_run_at: goal.last_run_at,
      completed_at: goal.completed_at,
      last_error: goal.last_error,
      inserted_at: goal.inserted_at,
      updated_at: goal.updated_at
    }
  end

  def serialize_event(%GoalEvent{} = event) do
    %{
      id: event.id,
      goal_id: event.goal_id,
      event_type: event.event_type,
      source: event.source,
      idempotency_key: event.idempotency_key,
      payload: event.payload,
      status: event.status,
      processed_at: event.processed_at,
      error_message: event.error_message,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  def serialize_run(%GoalRun{} = run) do
    %{
      id: run.id,
      goal_id: run.goal_id,
      event_id: run.event_id,
      execution_id: run.execution_id,
      attempt: run.attempt,
      status: run.status,
      verification_result: run.verification_result,
      metadata: run.metadata,
      started_at: run.started_at,
      finished_at: run.finished_at,
      error_message: run.error_message,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def eligible_status?(status), do: status in @eligible_statuses

  defp fetch_goal(id_or_name) do
    case resolve_goal(id_or_name) do
      %Goal{} = goal -> {:ok, goal}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_goal(%Goal{} = goal), do: goal

  defp resolve_goal(id_or_name) when is_binary(id_or_name) do
    case Ecto.UUID.cast(id_or_name) do
      {:ok, id} -> Repo.get(Goal, id) || Repo.get_by(Goal, name: id_or_name)
      :error -> Repo.get_by(Goal, name: id_or_name)
    end
  end

  defp resolve_goal(_id_or_name), do: nil

  defp change_status(id_or_name, status, extra_attrs \\ []) do
    with {:ok, goal} <- fetch_goal(id_or_name),
         :ok <- StateMachine.transition(goal.status, status) do
      update_goal(goal.id, Keyword.put(extra_attrs, :status, status) |> Map.new())
    end
  end

  defp resume_attrs(id_or_name) do
    goal = get_goal!(id_or_name)

    if is_nil(goal.next_run_at) do
      case interval_seconds(goal.trigger) do
        nil -> []
        seconds -> [next_run_at: DateTime.add(DateTime.utc_now(), seconds, :second)]
      end
    else
      []
    end
  end

  defp validate_status_change(_goal, nil), do: :ok

  defp validate_status_change(goal, status),
    do: StateMachine.transition(goal.status, to_string(status))

  defp create_or_get_event(goal, event_type, payload, opts) do
    idempotency_key = Keyword.get(opts, :idempotency_key)

    existing =
      if is_binary(idempotency_key) and idempotency_key != "" do
        Repo.get_by(GoalEvent, goal_id: goal.id, idempotency_key: idempotency_key)
      end

    if existing do
      {:ok, existing, false}
    else
      attrs = %{
        goal_id: goal.id,
        event_type: event_type,
        source: opts |> Keyword.get(:source, "manual") |> to_string(),
        idempotency_key: idempotency_key,
        payload: payload,
        status: "queued"
      }

      case %GoalEvent{} |> GoalEvent.changeset(attrs) |> Repo.insert() do
        {:ok, event} ->
          {:ok, event, true}

        {:error, changeset} ->
          case Repo.get_by(GoalEvent, goal_id: goal.id, idempotency_key: idempotency_key) do
            %GoalEvent{} = event -> {:ok, event, false}
            nil -> {:error, changeset}
          end
      end
    end
  end

  defp dispatch_event(event_id, opts) do
    if Keyword.get(opts, :async, true) do
      Processor.dispatch(event_id, opts)
    else
      Processor.process(event_id, opts)
    end
  end

  defp claim_due_goal(%Goal{next_run_at: slot} = goal, now) do
    case interval_seconds(goal.trigger) do
      nil ->
        :not_claimed

      seconds ->
        next_run_at = DateTime.add(now, seconds, :second)

        query =
          from g in Goal,
            where: g.id == ^goal.id and g.status == "active" and g.next_run_at == ^slot

        case Repo.update_all(query, set: [next_run_at: next_run_at]) do
          {1, _} -> {:ok, slot}
          _ -> :not_claimed
        end
    end
  end

  defp normalize_goal_attrs(attrs, mode) do
    attrs = normalize_keys(attrs)

    attrs =
      if mode == :create or Map.has_key?(attrs, :autonomy_level) do
        Map.put(attrs, :autonomy_level, Autonomy.normalize_level(Map.get(attrs, :autonomy_level)))
      else
        attrs
      end

    if mode == :create or Map.has_key?(attrs, :trigger) do
      trigger = Map.get(attrs, :trigger, %{}) || %{}

      attrs
      |> Map.put(:trigger, trigger)
      |> maybe_set_next_run_at(trigger)
    else
      attrs
    end
  end

  defp maybe_set_next_run_at(attrs, trigger) do
    if is_nil(Map.get(attrs, :next_run_at)) do
      case interval_seconds(trigger) do
        nil ->
          attrs

        seconds ->
          Map.put(attrs, :next_run_at, DateTime.add(DateTime.utc_now(), seconds, :second))
      end
    else
      attrs
    end
  end

  defp interval_seconds(trigger) when is_map(trigger) do
    value = Map.get(trigger, "every_seconds") || Map.get(trigger, :every_seconds)

    case value do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp interval_seconds(_trigger), do: nil

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    if key in @goal_attrs, do: String.to_atom(key), else: key
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [g], field(g, ^field) == ^value)
end
