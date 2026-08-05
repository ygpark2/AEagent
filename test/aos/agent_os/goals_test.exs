defmodule AOS.AgentOS.GoalsTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Core.{Execution, GoalRun}
  alias AOS.AgentOS.Goals
  alias AOS.AgentOS.Goals.Processor
  alias AOS.Repo

  test "creates a durable goal and deduplicates event-triggered runs" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "release-readiness",
               objective: "Keep the release ready for deployment",
               goal_type: "ongoing",
               trigger: %{"type" => "manual"},
               autonomy_level: "supervised"
             })

    assert {:ok, first_event} =
             Goals.trigger(goal.id, "manual", %{"reason" => "operator request"},
               source: "test",
               idempotency_key: "release-readiness-1",
               async: false,
               start_immediately: false
             )

    assert {:ok, duplicate_event} =
             Goals.trigger(goal.id, "manual", %{"reason" => "duplicate delivery"},
               source: "test",
               idempotency_key: "release-readiness-1",
               async: false,
               start_immediately: false
             )

    assert duplicate_event.id == first_event.id
    assert duplicate_event.payload == first_event.payload

    [run] = Goals.list_runs(goal.id)
    assert run.event_id == first_event.id
    assert run.status == "queued"

    execution = Repo.get!(Execution, run.execution_id)
    assert execution.goal_id == goal.id
    assert execution.trigger_kind == "goal:manual"
    assert Goals.get_event(first_event.id).status == "dispatched"
  end

  test "verifies a one-shot goal when its execution reaches a terminal state" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "publish-report",
               objective: "Publish the weekly report",
               goal_type: "one_shot",
               success_criteria: %{"type" => "result_contains", "value" => "published"}
             })

    assert {:ok, event} =
             Goals.trigger(goal.id, "manual", %{},
               async: false,
               start_immediately: false
             )

    run = Goals.list_runs(goal.id) |> Enum.find(&(&1.event_id == event.id))
    execution = Repo.get!(Execution, run.execution_id)
    now = DateTime.utc_now()

    terminal_execution = %{
      execution
      | status: "succeeded",
        success: true,
        final_result: "The report was published successfully.",
        started_at: now,
        finished_at: now
    }

    assert {:ok, _goal} = Processor.handle_execution_terminal(terminal_execution)

    assert %{status: "succeeded"} = Goals.get_goal!(goal.id)

    assert %GoalRun{status: "succeeded"} = stored_run = Repo.get!(GoalRun, run.id)
    assert stored_run.verification_result["passed"] == true
  end

  test "interval goals are claimed once and advance their next run time" do
    now = DateTime.utc_now()

    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "hourly-health-check",
               objective: "Check the service health",
               trigger: %{"type" => "interval", "every_seconds" => 60},
               next_run_at: DateTime.add(now, -1, :second)
             })

    assert %{dispatched: 1, skipped: 0} =
             Goals.dispatch_due_goals(now,
               async: false,
               execution_async: false,
               start_immediately: false
             )

    updated = Goals.get_goal!(goal.id)
    assert DateTime.compare(updated.next_run_at, now) == :gt
    assert [%{event_type: "schedule", source: "scheduler"}] = Goals.list_events(goal.id)
  end
end
