defmodule AOS.AgentOS.Execution.CheckpointPayload do
  @moduledoc """
  Builder and validator for checkpoint artifact payloads.
  """

  def build(context, node_id, next_node_id) do
    standard = %{
      feedback: fetch_key(context, :feedback),
      evaluation_score: fetch_key(context, :evaluation_score),
      evaluation_feedback: fetch_key(context, :evaluation_feedback),
      result: fetch_key(context, :result),
      execution_result: fetch_key(context, :execution_result),
      history: serialize_history(fetch_key(context, :history, [])),
      cost_usd: fetch_key(context, :cost_usd, 0.0),
      estimated_cost: fetch_key(context, :estimated_cost, 0.0),
      llm_usage: fetch_key(context, :llm_usage, []),
      selected_skills: fetch_key(context, :selected_skills, []),
      skills: fetch_key(context, :skills, []),
      goal_id: fetch_key(context, :goal_id),
      goal_event_id: fetch_key(context, :goal_event_id),
      goal_run_id: fetch_key(context, :goal_run_id),
      goal_name: fetch_key(context, :goal_name),
      goal_objective: fetch_key(context, :goal_objective),
      goal_success_criteria: fetch_key(context, :goal_success_criteria),
      goal_constraints: fetch_key(context, :goal_constraints),
      goal_context: fetch_key(context, :goal_context),
      goal_event: fetch_key(context, :goal_event),
      artifacts: fetch_key(context, :artifacts),
      node_outputs: fetch_key(context, :node_outputs),
      inputs: fetch_key(context, :inputs),
      execution_history: fetch_key(context, :execution_history)
    }

    standard_keys =
      Map.keys(standard) ++
        Enum.map(Map.keys(standard), &to_string/1) ++
        [:custom_fields, "custom_fields"]

    system_keys = ~w(
      harness_manifest harness_budget_state graph_nodes dag_nodes dag_run_id
      dag_node_id execution_history dag_inputs inputs node_outputs notify task session_id
      execution_id workflow_id strategy_id engine domain autonomy_level
    )

    custom =
      context
      |> Enum.reject(fn {k, _v} ->
        str = to_string(k)
        str in standard_keys or str in system_keys or String.starts_with?(str, "harness_")
      end)
      |> Enum.map(fn {k, v} -> {k, json_safe(v)} end)
      |> Map.new()

    custom_subfields =
      case fetch_key(context, :custom_fields) do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
        _ -> %{}
      end

    merged_context =
      custom
      |> Map.merge(custom_subfields)
      |> Map.merge(standard)

    %{
      node_id: to_string(node_id),
      next_node_id: if(next_node_id, do: to_string(next_node_id), else: nil),
      context: merged_context
    }
  end

  def validate(%{"node_id" => node_id, "context" => context})
      when is_binary(node_id) and is_map(context),
      do: :ok

  def validate(%{node_id: node_id, context: context}) when is_binary(node_id) and is_map(context),
    do: :ok

  def validate(%{"context" => context}) when is_map(context), do: :ok
  def validate(%{context: context}) when is_map(context), do: :ok

  def validate(_payload), do: {:error, :invalid_checkpoint_payload}

  defp fetch_key(map, key, default \\ nil)

  defp fetch_key(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp fetch_key(_map, _key, default), do: default

  defp json_safe({role, content})
       when (is_binary(role) or is_atom(role)) and is_binary(content) do
    %{role: to_string(role), content: content}
  end

  defp json_safe(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)
  end

  defp json_safe(list) when is_list(list) do
    Enum.map(list, &json_safe/1)
  end

  defp json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  end

  defp json_safe(other), do: other

  defp serialize_history(history) when is_list(history) do
    Enum.map(history, fn
      {role, content} -> %{role: to_string(role), content: content}
      %{role: role, content: content} -> %{role: to_string(role), content: content}
      other -> %{role: "system", content: inspect(other)}
    end)
  end

  defp serialize_history(_history), do: []
end
