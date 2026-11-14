defmodule AOS.AgentOS.Execution.WatchdogTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Core.DAGRun
  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Execution.Store
  alias AOS.AgentOS.Execution.Watchdog
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Orchestration.DAGStore
  alias AOS.AgentOS.ToolUse.ApprovalQueue
  alias AOS.Repo

  setup do
    # Start a test instance of Watchdog with disabled recurring interval
    {:ok, watchdog_pid} =
      start_supervised(
        {Watchdog, [name: :test_watchdog, interval_ms: 0, default_timeout_ms: 5_000]}
      )

    %{watchdog: watchdog_pid}
  end

  test "leaves active executions within timeout unchanged", %{watchdog: watchdog} do
    {:ok, execution} = Executions.enqueue("active task", start_immediately: false)
    {:ok, running} = Executions.mark_running(execution.id, %{started_at: DateTime.utc_now()})

    assert {:ok, timed_out} = Watchdog.check_timeouts(watchdog)
    assert timed_out == []

    updated = Executions.get_execution!(running.id)
    assert updated.status == "running"
  end

  test "transitions executions exceeding SLA timeout to timed_out and emits event", %{
    watchdog: watchdog
  } do
    {:ok, execution} = Executions.enqueue("stalled task", start_immediately: false)
    past_started_at = DateTime.add(DateTime.utc_now(), -10_000, :millisecond)
    {:ok, running} = Executions.mark_running(execution.id, %{started_at: past_started_at})

    assert {:ok, [timed_out]} = Watchdog.check_timeouts(watchdog)
    assert timed_out.id == running.id

    updated = Executions.get_execution!(running.id)
    assert updated.status == "timed_out"
    assert updated.failure_category == "timed_out"
    assert updated.finished_at != nil

    events = EventStore.list_events(running.id) |> Enum.map(&EventStore.serialize/1)
    assert Enum.any?(events, &(&1.event_type == "execution.timed_out"))
  end

  test "cancels pending approval requests when execution times out", %{watchdog: watchdog} do
    {:ok, execution} = Executions.enqueue("approval task", start_immediately: false)
    past_started_at = DateTime.add(DateTime.utc_now(), -10_000, :millisecond)
    {:ok, running} = Executions.mark_running(execution.id, %{started_at: past_started_at})

    {:ok, approval_request} =
      ApprovalQueue.create_request(%{
        execution_id: running.id,
        session_id: running.session_id,
        server_id: "internal",
        tool_name: "write_file",
        risk_tier: "medium",
        arguments: %{"path" => "lib/sample.ex"}
      })

    assert approval_request.status == "pending"

    assert {:ok, [_]} = Watchdog.check_timeouts(watchdog)

    req = ApprovalQueue.get_request!(approval_request.id)
    assert req.status == "rejected"
    assert req.decision_reason =~ "timed out"
  end

  test "transitions associated DAG run to timed_out", %{watchdog: watchdog} do
    {:ok, execution} = Executions.enqueue("dag task", start_immediately: false)
    Store.update_execution(execution.id, %{engine: "dag"})

    {:ok, dag_run} =
      %DAGRun{}
      |> DAGRun.changeset(%{
        execution_id: execution.id,
        definition: %{},
        status: "running"
      })
      |> Repo.insert()

    past_started_at = DateTime.add(DateTime.utc_now(), -10_000, :millisecond)
    {:ok, _running} = Executions.mark_running(execution.id, %{started_at: past_started_at})

    assert {:ok, [_]} = Watchdog.check_timeouts(watchdog)

    updated_run = DAGStore.get_run!(dag_run.id)
    assert updated_run.status == "timed_out"
  end
end
