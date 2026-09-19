defmodule AOS.AgentOS.ToolUse.ApprovalServiceTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.ApprovalService

  setup do
    {:ok, execution} = Executions.enqueue("approval trace task", start_immediately: false)

    opts = [execution_id: execution.id, session_id: execution.session_id]

    %{execution: execution, opts: opts}
  end

  defp policy_events(execution_id) do
    execution_id
    |> EventStore.list_events()
    |> Enum.map(&EventStore.serialize/1)
    |> Enum.filter(&String.starts_with?(&1.event_type, "policy."))
  end

  test "traces a tool-allowlist rejection when a skill restricts the tool", %{
    execution: execution,
    opts: opts
  } do
    selected_skills = [%{execution_mode: "assisted", required_tools: [], permissions: []}]
    metadata = %{risk_tier: "low", requires_confirmation: false}

    assert :rejected =
             ApprovalService.request_tool_confirmation(
               "internal",
               "restricted_tool",
               %{},
               nil,
               metadata,
               Keyword.put(opts, :selected_skills, selected_skills)
             )

    assert [
             %{
               event_type: "policy.blocked",
               source: "approval_service",
               payload: %{
                 "policy" => "ToolAllowlist",
                 "reason" => "tool_not_permitted_for_skills",
                 "tool_name" => "internal__restricted_tool"
               }
             }
           ] = policy_events(execution.id)
  end

  test "traces a tool-allowlist rejection under a read_only autonomy level", %{
    execution: execution,
    opts: opts
  } do
    metadata = %{risk_tier: "medium", requires_confirmation: true}

    assert :rejected =
             ApprovalService.request_tool_confirmation(
               "internal",
               "write_file",
               %{},
               nil,
               metadata,
               Keyword.put(opts, :autonomy_level, "read_only")
             )

    assert [%{event_type: "policy.blocked", payload: %{"reason" => reason}}] =
             policy_events(execution.id)

    assert reason == "tool_not_allowed_for_autonomy_level"
  end

  test "traces an auto-approved tool-allowlist decision under autonomous mode", %{
    execution: execution,
    opts: opts
  } do
    metadata = %{risk_tier: "low", requires_confirmation: false}

    assert :approved =
             ApprovalService.request_tool_confirmation(
               "internal",
               "read_file",
               %{},
               nil,
               metadata,
               Keyword.put(opts, :autonomy_level, "autonomous")
             )

    assert [%{event_type: "policy.allowed", payload: %{"reason" => "auto_approved"}}] =
             policy_events(execution.id)
  end

  test "traces a pending durable approval check when no notify_pid is present", %{
    execution: execution,
    opts: opts
  } do
    metadata = %{risk_tier: "high", requires_confirmation: true}

    assert {:pending, _request} =
             ApprovalService.request_tool_confirmation(
               "internal",
               "execute_command",
               %{},
               nil,
               metadata,
               Keyword.put(opts, :autonomy_level, "supervised")
             )

    assert [%{event_type: "policy.pending", payload: %{"policy" => "ApprovalCheck"}}] =
             policy_events(execution.id)
  end
end
