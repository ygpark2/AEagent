defmodule AOS.AgentOS.Execution.ResumeContext do
  @moduledoc """
  Typed resume context restored from checkpoints or resume seeds.
  """

  alias AOS.AgentOS.Core.NodeId

  defstruct [
    :feedback,
    :result,
    :execution_result,
    :cost_usd,
    :estimated_cost,
    :checkpoint_artifact_id,
    :resume_mode,
    :resume_from_node,
    :goal_id,
    :goal_event_id,
    :goal_run_id,
    :goal_name,
    :goal_objective,
    :goal_success_criteria,
    :goal_constraints,
    :goal_context,
    :goal_event,
    history: [],
    llm_usage: [],
    selected_skills: [],
    skills: []
  ]

  def from_map(context) when is_map(context) do
    history =
      context
      |> fetch("history", [])
      |> normalize_history()

    %__MODULE__{
      feedback: fetch(context, "feedback"),
      result: fetch(context, "result"),
      execution_result: fetch(context, "execution_result"),
      history: history,
      cost_usd: fetch(context, "cost_usd", 0.0),
      estimated_cost: fetch(context, "estimated_cost", 0.0),
      llm_usage: fetch(context, "llm_usage", []),
      selected_skills: fetch(context, "selected_skills", []),
      skills: fetch(context, "skills", []),
      checkpoint_artifact_id: fetch(context, "checkpoint_artifact_id"),
      resume_mode: fetch(context, "resume_mode"),
      resume_from_node: normalize_node(fetch(context, "resume_from_node")),
      goal_id: fetch(context, "goal_id"),
      goal_event_id: fetch(context, "goal_event_id"),
      goal_run_id: fetch(context, "goal_run_id"),
      goal_name: fetch(context, "goal_name"),
      goal_objective: fetch(context, "goal_objective"),
      goal_success_criteria: fetch(context, "goal_success_criteria", %{}),
      goal_constraints: fetch(context, "goal_constraints", %{}),
      goal_context: fetch(context, "goal_context", %{}),
      goal_event: fetch(context, "goal_event", %{})
    }
  end

  def to_map(%__MODULE__{} = context) do
    %{
      feedback: context.feedback,
      result: context.result,
      execution_result: context.execution_result,
      history: context.history,
      cost_usd: context.cost_usd,
      estimated_cost: context.estimated_cost,
      llm_usage: context.llm_usage,
      selected_skills: context.selected_skills,
      skills: context.skills,
      checkpoint_artifact_id: context.checkpoint_artifact_id,
      resume_mode: context.resume_mode,
      resume_from_node: context.resume_from_node,
      goal_id: context.goal_id,
      goal_event_id: context.goal_event_id,
      goal_run_id: context.goal_run_id,
      goal_name: context.goal_name,
      goal_objective: context.goal_objective,
      goal_success_criteria: context.goal_success_criteria,
      goal_constraints: context.goal_constraints,
      goal_context: context.goal_context,
      goal_event: context.goal_event
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fetch(context, key, default \\ nil) do
    Map.get(context, key, Map.get(context, normalize_key(key), default))
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("history"), do: :history
  defp normalize_key("feedback"), do: :feedback
  defp normalize_key("result"), do: :result
  defp normalize_key("execution_result"), do: :execution_result
  defp normalize_key("cost_usd"), do: :cost_usd
  defp normalize_key("estimated_cost"), do: :estimated_cost
  defp normalize_key("llm_usage"), do: :llm_usage
  defp normalize_key("selected_skills"), do: :selected_skills
  defp normalize_key("skills"), do: :skills
  defp normalize_key("checkpoint_artifact_id"), do: :checkpoint_artifact_id
  defp normalize_key("resume_mode"), do: :resume_mode
  defp normalize_key("resume_from_node"), do: :resume_from_node
  defp normalize_key("goal_id"), do: :goal_id
  defp normalize_key("goal_event_id"), do: :goal_event_id
  defp normalize_key("goal_run_id"), do: :goal_run_id
  defp normalize_key("goal_name"), do: :goal_name
  defp normalize_key("goal_objective"), do: :goal_objective
  defp normalize_key("goal_success_criteria"), do: :goal_success_criteria
  defp normalize_key("goal_constraints"), do: :goal_constraints
  defp normalize_key("goal_context"), do: :goal_context
  defp normalize_key("goal_event"), do: :goal_event
  defp normalize_key(key) when is_binary(key), do: key

  defp normalize_history(history) when is_list(history) do
    Enum.map(history, fn
      {role, content} -> {to_string(role), content}
      %{"role" => role, "content" => content} -> {to_string(role), content}
      %{role: role, content: content} -> {to_string(role), content}
      other -> {"system", inspect(other)}
    end)
  end

  defp normalize_history(_history), do: []

  defp normalize_node(nil), do: nil
  defp normalize_node(value) when is_atom(value), do: value
  defp normalize_node(value) when is_binary(value), do: NodeId.normalize(value)
end
