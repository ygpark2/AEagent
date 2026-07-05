defmodule AOS.AgentOS.WorkflowsTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.{ApprovalQueue, ApprovalService}
  alias AOS.AgentOS.Workflows

  test "creates workflow definitions and enqueues linked executions" do
    assert {:ok, workflow} =
             Workflows.create_workflow(%{
               name: "daily-research",
               description: "Daily research workflow",
               required_tools: ["internal__web_search"],
               policy_profile: %{"budget" => %{"max_cost_usd" => 1.0}},
               approval_policy: %{"high_risk" => "queue"}
             })

    assert {:ok, execution} =
             Workflows.enqueue_workflow(workflow.name, "research task", start_immediately: false)

    assert execution.workflow_id == workflow.id
    assert execution.status == "queued"

    replay = Executions.replay_execution(execution.id)
    assert replay.execution.workflow_id == workflow.id
    assert Enum.any?(replay.events, &(&1.event_type == "execution.queued"))
  end

  test "server-side approval requests are durable and added to execution timeline" do
    assert {:ok, workflow} = Workflows.create_workflow(%{name: "approval-flow"})

    assert {:ok, execution} =
             Workflows.enqueue_workflow(workflow.id, "write file", start_immediately: false)

    metadata = %{risk_tier: "high", requires_confirmation: true, retryable: false}

    assert {:pending, request} =
             ApprovalService.request_tool_confirmation(
               "internal",
               "write_file",
               %{"path" => "tmp.txt"},
               nil,
               metadata,
               execution_id: execution.id,
               session_id: execution.session_id,
               workflow_id: workflow.id,
               autonomy_level: "supervised"
             )

    assert request.status == "pending"
    assert request.workflow_id == workflow.id
    assert [pending] = ApprovalQueue.list_pending()
    assert pending.id == request.id

    replay = Executions.replay_execution(execution.id)
    assert Enum.any?(replay.events, &(&1.event_type == "approval.requested"))

    assert {:ok, approved} =
             ApprovalQueue.approve(request.id, %{
               decided_by: "operator",
               decision_reason: "expected write"
             })

    assert approved.status == "approved"

    replay = Executions.replay_execution(execution.id)
    assert Enum.any?(replay.events, &(&1.event_type == "approval.approved"))

    assert :approved =
             ApprovalService.request_tool_confirmation(
               "internal",
               "write_file",
               %{"path" => "tmp.txt"},
               nil,
               metadata,
               execution_id: Ecto.UUID.generate(),
               source_execution_id: execution.id,
               session_id: execution.session_id,
               workflow_id: workflow.id,
               autonomy_level: "supervised"
             )
  end
end
