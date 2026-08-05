defmodule AOS.AgentOS.Execution.CheckpointPayload do
  @moduledoc """
  Builder and validator for checkpoint artifact payloads.
  """

  def build(context, node_id, next_node_id) do
    %{
      node_id: to_string(node_id),
      next_node_id: if(next_node_id, do: to_string(next_node_id), else: nil),
      context: %{
        feedback: Map.get(context, :feedback),
        evaluation_score: Map.get(context, :evaluation_score),
        evaluation_feedback: Map.get(context, :evaluation_feedback),
        result: Map.get(context, :result),
        execution_result: Map.get(context, :execution_result),
        history: serialize_history(Map.get(context, :history, [])),
        cost_usd: Map.get(context, :cost_usd, 0.0),
        estimated_cost: Map.get(context, :estimated_cost, 0.0),
        llm_usage: Map.get(context, :llm_usage, []),
        selected_skills: Map.get(context, :selected_skills, []),
        skills: Map.get(context, :skills, []),
        goal_id: Map.get(context, :goal_id),
        goal_event_id: Map.get(context, :goal_event_id),
        goal_run_id: Map.get(context, :goal_run_id),
        goal_name: Map.get(context, :goal_name),
        goal_objective: Map.get(context, :goal_objective),
        goal_success_criteria: Map.get(context, :goal_success_criteria),
        goal_constraints: Map.get(context, :goal_constraints),
        goal_context: Map.get(context, :goal_context),
        goal_event: Map.get(context, :goal_event)
      }
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

  defp serialize_history(history) when is_list(history) do
    Enum.map(history, fn
      {role, content} -> %{role: to_string(role), content: content}
      %{role: role, content: content} -> %{role: to_string(role), content: content}
      other -> %{role: "system", content: inspect(other)}
    end)
  end

  defp serialize_history(_history), do: []
end
