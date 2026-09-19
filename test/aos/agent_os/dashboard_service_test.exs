defmodule AOS.AgentOS.DashboardServiceTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.DashboardService
  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Tools

  test "returns an empty timeline for a nil or unknown execution id" do
    assert DashboardService.timeline_entries(nil) == []
    assert DashboardService.timeline_entries(Ecto.UUID.generate()) == []
  end

  test "merges execution events, tool audits, and delegation traces in chronological order" do
    {:ok, execution} = Executions.enqueue("timeline task", start_immediately: false)

    {:ok, _audit} =
      Tools.create_audit(%{
        execution_id: execution.id,
        session_id: execution.session_id,
        server_id: "internal",
        tool_name: "read_file",
        risk_tier: "low",
        status: "succeeded",
        approval_required: false,
        approval_status: "not_required",
        arguments: %{"path" => "a.txt"},
        normalized_result: %{},
        attempts: 1,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    {:ok, _trace} =
      Executions.create_delegation_trace(%{
        session_id: execution.session_id,
        parent_execution_id: execution.id,
        task: "delegated subtask",
        status: "succeeded",
        position: 0,
        result_summary: "done"
      })

    entries = DashboardService.timeline_entries(execution.id)

    assert Enum.map(entries, & &1.category) |> Enum.sort() == ["delegation", "event", "tool"]

    timestamps = Enum.map(entries, & &1.timestamp)
    assert timestamps == Enum.sort(timestamps, DateTime)

    event_entry = Enum.find(entries, &(&1.category == "event"))
    assert event_entry.badge == "execution.queued"

    tool_entry = Enum.find(entries, &(&1.category == "tool"))
    assert tool_entry.title == "internal__read_file"
    assert tool_entry.badge == "tool.succeeded"

    delegation_entry = Enum.find(entries, &(&1.category == "delegation"))
    assert delegation_entry.title == "delegated subtask"
    assert delegation_entry.subtitle == "done"
  end

  test "event titles surface approval and policy metadata" do
    {:ok, execution} = Executions.enqueue("timeline approval task", start_immediately: false)

    {:ok, _} =
      EventStore.append_event(%{
        execution_id: execution.id,
        session_id: execution.session_id,
        event_type: "approval.requested",
        source: "approval_queue",
        payload: %{"tool_name" => "write_file"}
      })

    {:ok, _} =
      EventStore.append_event(%{
        execution_id: execution.id,
        session_id: execution.session_id,
        event_type: "policy.blocked",
        source: "policy_gate",
        payload: %{"policy" => "SafetyPolicy", "reason" => "dangerous_intent"}
      })

    entries = DashboardService.timeline_entries(execution.id)

    assert Enum.any?(entries, &(&1.title == "approval.requested — write_file"))
    assert Enum.any?(entries, &(&1.title == "policy.blocked — SafetyPolicy (dangerous_intent)"))
  end
end
