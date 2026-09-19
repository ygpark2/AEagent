defmodule AOS.AgentOS.Core.PolicyGate do
  @moduledoc "Shared policy gate used by graph and DAG execution engines."

  alias AOS.AgentOS.Core.PolicyTrace
  alias AOS.AgentOS.Policies.{BudgetPolicy, DomainPolicy, SafetyPolicy}

  @active_policies [SafetyPolicy, BudgetPolicy, DomainPolicy]

  def check(context, node_id) do
    Enum.reduce_while(@active_policies, {:ok, context}, fn policy, {:ok, acc_context} ->
      case policy.check(acc_context, node_id) do
        {:ok, updated_context} ->
          trace(acc_context, policy, :allowed, node_id, nil)
          {:cont, {:ok, updated_context}}

        {:error, reason} ->
          trace(acc_context, policy, :blocked, node_id, reason)
          {:halt, {:error, reason}}
      end
    end)
  end

  def blocking_reason?({:approval_required, _request}), do: true
  def blocking_reason?(reason) when reason in [:evaluation_required, :out_of_budget], do: true
  def blocking_reason?(reason) when reason in [:too_many_loops, :dangerous_intent], do: true
  def blocking_reason?(reason) when reason in [:dangerous_output, :dangerous_command], do: true
  def blocking_reason?(:unsafe_write_path), do: true
  def blocking_reason?(_reason), do: false

  defp trace(context, policy, decision, node_id, reason) do
    PolicyTrace.record(context, policy, decision,
      source: "policy_gate",
      node_id: node_id,
      reason: reason,
      input_summary: input_summary(context)
    )
  end

  defp input_summary(context) do
    %{
      "domain" => stringify(Map.get(context, :domain)),
      "autonomy_level" => stringify(Map.get(context, :autonomy_level)),
      "loop_count" => context |> Map.get(:execution_history, []) |> length(),
      "cost_usd" => Map.get(context, :cost_usd) || Map.get(context, :estimated_cost)
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
