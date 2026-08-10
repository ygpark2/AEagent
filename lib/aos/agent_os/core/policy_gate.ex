defmodule AOS.AgentOS.Core.PolicyGate do
  @moduledoc "Shared policy gate used by graph and DAG execution engines."

  alias AOS.AgentOS.Policies.{BudgetPolicy, DomainPolicy, SafetyPolicy}

  @active_policies [SafetyPolicy, BudgetPolicy, DomainPolicy]

  def check(context, node_id) do
    Enum.reduce_while(@active_policies, {:ok, context}, fn policy, {:ok, acc_context} ->
      case policy.check(acc_context, node_id) do
        {:ok, updated_context} -> {:cont, {:ok, updated_context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def blocking_reason?({:approval_required, _request}), do: true
  def blocking_reason?(reason) when reason in [:evaluation_required, :out_of_budget], do: true
  def blocking_reason?(reason) when reason in [:too_many_loops, :dangerous_intent], do: true
  def blocking_reason?(reason) when reason in [:dangerous_output, :dangerous_command], do: true
  def blocking_reason?(:unsafe_write_path), do: true
  def blocking_reason?(_reason), do: false
end
