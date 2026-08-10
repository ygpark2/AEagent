defmodule AOS.AgentOS.Harness.FailureAttribution do
  @moduledoc "Standard failure taxonomy and evidence for harness episodes."

  def classify(reason, context \\ %{}, phase \\ nil) do
    category = category(reason)

    %{
      category: category,
      source: source(category),
      phase: phase || Map.get(context, :harness_phase, "execution"),
      reason: inspect(reason),
      retryable: retryable?(category),
      node_id: Map.get(context, :dag_node_id) || Map.get(context, :current_node),
      tool: Map.get(context, :last_tool),
      observed_at: DateTime.utc_now()
    }
  end

  def category({:verification_failed, _report}), do: "verification_failed"
  def category({:harness_budget_exceeded, _reason}), do: "budget_exceeded"
  def category({:harness_budget_exceeded, _kind, _actual, _limit}), do: "budget_exceeded"
  def category({:harness_permission_denied, _tool}), do: "permission_denied"
  def category({:approval_required, _request}), do: "user_intervention_required"
  def category(:node_timeout), do: "timeout"
  def category(:dag_timeout), do: "timeout"
  def category(:out_of_budget), do: "budget_exceeded"
  def category(:too_many_loops), do: "budget_exceeded"
  def category(:evaluation_required), do: "policy_blocked"
  def category(:dangerous_intent), do: "policy_blocked"
  def category(:dangerous_output), do: "policy_blocked"
  def category(:dangerous_command), do: "policy_blocked"
  def category(:unsafe_write_path), do: "policy_blocked"
  def category({:delegation_failed, _details}), do: "delegation_failed"
  def category(:quality_refinement_exhausted), do: "quality_low"
  def category(:invalid_graph_definition), do: "invalid_graph"

  def category(reason) when is_binary(reason),
    do:
      if(String.contains?(String.downcase(reason), "tool"),
        do: "tool_error",
        else: "execution_error"
      )

  def category(_reason), do: "execution_error"

  defp source("verification_failed"), do: "verification"
  defp source("tool_error"), do: "tool"
  defp source("permission_denied"), do: "permission"
  defp source("policy_blocked"), do: "policy"
  defp source("budget_exceeded"), do: "budget"
  defp source("timeout"), do: "runtime"
  defp source("delegation_failed"), do: "orchestration"
  defp source(_category), do: "node"

  defp retryable?(category),
    do: category in ["timeout", "tool_error", "execution_error", "verification_failed"]
end
