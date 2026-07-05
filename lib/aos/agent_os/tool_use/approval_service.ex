defmodule AOS.AgentOS.ToolUse.ApprovalService do
  @moduledoc """
  Handles approval flow for tool execution.
  """

  alias AOS.AgentOS.{Autonomy, Tools}
  alias AOS.AgentOS.ToolUse.ApprovalQueue

  def request_tool_confirmation(server_id, tool_name, args, notify_pid, metadata, opts) do
    autonomy_level = Autonomy.normalize_level(Keyword.get(opts, :autonomy_level))
    selected_skills = Keyword.get(opts, :selected_skills, [])

    cond do
      not Tools.tool_permitted_for_skills?(
        server_id,
        tool_name,
        selected_skills
      ) ->
        :rejected

      not Autonomy.tool_allowed?(autonomy_level, metadata) ->
        :rejected

      Autonomy.auto_approve_tool?(autonomy_level, metadata) ->
        :approved

      approved_request?(server_id, tool_name, args, opts) ->
        :approved

      is_nil(notify_pid) ->
        create_pending_request(server_id, tool_name, args, metadata, opts)

      true ->
        approval_ref = "approval-" <> Integer.to_string(System.unique_integer([:positive]))
        send(notify_pid, {:request_tool_confirmation, approval_ref, tool_name, args, self()})

        receive do
          {:tool_approval, ^approval_ref, decision} -> decision
        after
          300_000 -> :rejected
        end
    end
  end

  defp approved_request?(server_id, tool_name, args, opts) do
    execution_ids = [
      Keyword.get(opts, :execution_id),
      Keyword.get(opts, :source_execution_id)
    ]

    case ApprovalQueue.find_approved_tool_request(server_id, tool_name, args, execution_ids) do
      nil -> false
      _request -> true
    end
  end

  defp create_pending_request(server_id, tool_name, args, metadata, opts) do
    case ApprovalQueue.create_request(%{
           execution_id: Keyword.get(opts, :execution_id),
           session_id: Keyword.get(opts, :session_id),
           workflow_id: Keyword.get(opts, :workflow_id),
           server_id: server_id,
           tool_name: tool_name,
           arguments: args,
           risk_tier: metadata.risk_tier,
           requested_by: "agent"
         }) do
      {:ok, request} -> {:pending, request}
      {:error, _changeset} -> :rejected
    end
  end
end
