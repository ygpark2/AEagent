defmodule AOS.AgentOS.Core.PolicyTrace do
  @moduledoc """
  Persists structured allow/reject/pending policy decisions to the execution
  timeline (`agent_execution_events`) so they can be audited and replayed.
  """

  alias AOS.AgentOS.Execution.EventStore

  @type decision :: :allowed | :blocked | :pending

  @doc """
  Records a policy decision as an `agent_execution_events` row.

  `ids` is either the execution context map or an opts keyword list -
  anything with `:execution_id`/`:session_id`/`:workflow_id` keys. No-op
  when `:execution_id` is absent, since the event can't be replayed without it.

  Recognized `meta` keys: `:source`, `:node_id`, `:tool_name`,
  `:reason`, `:input_summary`.
  """
  def record(ids, policy, decision, meta \\ [])
      when decision in [:allowed, :blocked, :pending] do
    ids = to_id_map(ids)

    if execution_id = Map.get(ids, :execution_id) do
      EventStore.append_event(%{
        execution_id: execution_id,
        session_id: Map.get(ids, :session_id),
        workflow_id: Map.get(ids, :workflow_id),
        event_type: "policy.#{decision}",
        source: Keyword.get(meta, :source, "policy_gate"),
        payload: %{
          "policy" => policy_name(policy),
          "decision" => Atom.to_string(decision),
          "reason" => reason_text(Keyword.get(meta, :reason)),
          "node_id" => text(Keyword.get(meta, :node_id)),
          "tool_name" => text(Keyword.get(meta, :tool_name)),
          "input_summary" => Keyword.get(meta, :input_summary, %{})
        }
      })
    end

    :ok
  end

  defp to_id_map(ids) when is_map(ids), do: ids
  defp to_id_map(ids) when is_list(ids), do: Map.new(ids)

  defp policy_name(policy) when is_atom(policy) and not is_nil(policy) do
    case Module.split(policy) do
      [] -> to_string(policy)
      parts -> List.last(parts)
    end
  end

  defp policy_name(policy), do: to_string(policy)

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp text(nil), do: nil
  defp text(value), do: to_string(value)
end
