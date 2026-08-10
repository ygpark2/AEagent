defmodule AOS.AgentOS.Harness.Episode do
  @moduledoc "Lifecycle and trace API for auditable harness episodes."

  alias AOS.AgentOS.Core.Execution
  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Harness.{FailureAttribution, Manifest, Store}

  def ensure(%Execution{} = execution, context, opts \\ []) do
    if not Config.harness_enabled?() do
      {:ok, nil}
    else
      do_ensure(execution, context, opts)
    end
  end

  defp do_ensure(%Execution{} = execution, context, opts) do
    case Store.get_episode_by_execution(execution.id) do
      nil ->
        with {:ok, manifest} <-
               Manifest.for_context(Map.put(context, :task, execution.task), opts),
             {:ok, episode} <-
               Store.create_episode(%{
                 execution_id: execution.id,
                 status: execution.status || "queued",
                 manifest: manifest,
                 budget: Manifest.get(manifest, :budgets, %{}),
                 summary: %{}
               }),
             {:ok, _trace} <-
               trace_episode(episode, "task", "specified", %{
                 task: execution.task,
                 domain: execution.domain,
                 engine: execution.engine,
                 manifest_version: Manifest.get(manifest, :version, 1)
               }) do
          {:ok, episode}
        end

      episode ->
        {:ok, episode}
    end
  end

  def manifest_for_execution(execution_id) do
    case Store.get_episode_by_execution(execution_id) do
      nil -> {:error, :harness_episode_not_found}
      episode -> {:ok, episode.manifest}
    end
  end

  def attach_dag_run(execution_id, dag_run_id) do
    case Store.get_episode_by_execution(execution_id) do
      nil ->
        {:ok, nil}

      episode ->
        Store.update_episode(episode, %{dag_run_id: dag_run_id})
    end
  end

  def mark_running(execution_id) do
    with %{} = episode <- Store.get_episode_by_execution(execution_id),
         {:ok, updated} <-
           Store.update_episode(episode, %{
             status: "running",
             started_at: episode.started_at || DateTime.utc_now()
           }),
         {:ok, _trace} <- trace(execution_id, "lifecycle", "running", %{}) do
      {:ok, updated}
    else
      nil -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  def finish(execution_id, status, context, reason \\ nil) do
    case Store.get_episode_by_execution(execution_id) do
      nil ->
        {:ok, nil}

      episode ->
        attribution =
          if reason, do: FailureAttribution.classify(reason, context), else: %{}

        verification = Map.get(context, :harness_verification, %{})
        summary = summary_from_context(context)

        with {:ok, updated} <-
               Store.update_episode(episode, %{
                 status: to_string(status),
                 verification: json_map(verification),
                 failure_attribution: json_map(attribution),
                 summary: json_map(summary),
                 finished_at: DateTime.utc_now()
               }),
             {:ok, _trace} <-
               trace(execution_id, "lifecycle", "finished", %{
                 status: to_string(status),
                 reason: json_value(reason),
                 verification: verification,
                 failure_attribution: attribution
               }) do
          {:ok, updated}
        end
    end
  end

  def record_failure(execution_id, reason, context) do
    attribution = FailureAttribution.classify(reason, context)

    trace(execution_id, "failure", "attributed", attribution,
      idempotency_key: "failure:#{safe_key(reason)}"
    )
  end

  def record_intervention(execution_id, attrs) when is_binary(execution_id) do
    case Store.get_episode_by_execution(execution_id) do
      nil ->
        {:ok, nil}

      episode ->
        with {:ok, updated} <-
               Store.update_episode(episode, %{
                 intervention_count: (episode.intervention_count || 0) + 1
               }),
             {:ok, _trace} <- trace(execution_id, "intervention", "recorded", attrs) do
          {:ok, updated}
        end
    end
  end

  def record_intervention(_execution_id, _attrs), do: {:ok, nil}

  def trace(execution_id, trace_type, phase, payload, opts \\ []) do
    case Store.get_episode_by_execution(execution_id) do
      nil ->
        {:ok, nil}

      episode ->
        trace_episode(episode, trace_type, phase, payload, opts)
    end
  end

  defp trace_episode(episode, trace_type, phase, payload, opts \\ []) do
    Store.append_trace(%{
      episode_id: episode.id,
      execution_id: episode.execution_id,
      trace_type: to_string(trace_type),
      phase: to_string(phase),
      payload: json_map(payload),
      source: Keyword.get(opts, :source, "harness"),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    })
  end

  defp summary_from_context(context) do
    %{
      result: Map.get(context, :result) || Map.get(context, :execution_result),
      execution_history_length: length(Map.get(context, :execution_history, [])),
      cost_usd: Map.get(context, :cost_usd, 0.0),
      tool_calls: get_in(context, [:harness_budget_state, :tool_calls]) || 0
    }
  end

  defp safe_key(reason),
    do: reason |> inspect() |> String.replace(~r/\s+/, "_") |> String.slice(0, 120)

  defp json_map(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  defp json_map(_value), do: %{}

  defp json_value(nil), do: nil
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(value) when is_atom(value), do: to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_map(value), do: json_map(value)
  defp json_value(value), do: inspect(value)
end
