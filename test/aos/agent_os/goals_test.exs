defmodule AOS.AgentOS.GoalsTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Core.{Execution, GoalEvent, GoalRun}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Goals

  test "creates goals with normalized attributes and interval scheduling" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               "name" => "service-health",
               "objective" => "Keep the service healthy",
               "trigger" => %{"every_seconds" => "60"},
               "autonomy_level" => "AUTONOMOUS"
             })

    assert goal.name == "service-health"
    assert goal.autonomy_level == "autonomous"
    assert %DateTime{} = goal.next_run_at
    assert Goals.get_goal("service-health").id == goal.id
  end

  test "enforces lifecycle transitions through the public API" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "pauseable-goal",
               objective: "Pause and resume this goal"
             })

    assert {:ok, paused} = Goals.pause_goal(goal.id)
    assert paused.status == "paused"
    assert paused.version == goal.version + 1

    assert {:ok, active} = Goals.resume_goal(goal.id)
    assert active.status == "active"

    assert {:ok, cancelled} = Goals.cancel_goal(goal.id)
    assert cancelled.status == "cancelled"

    assert {:error, {:invalid_goal_status_transition, "cancelled", "active"}} =
             Goals.resume_goal(goal.id)
  end

  test "creates one execution per idempotent event" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "incident-response",
               objective: "Resolve the incoming incident",
               success_criteria: %{"type" => "result_contains", "value" => "resolved"}
             })

    opts = [
      async: false,
      execution_async: false,
      start_immediately: false,
      source: "test",
      idempotency_key: "incident-123"
    ]

    assert {:ok, event} =
             Goals.trigger(goal.id, "incident.created", %{"id" => "INC-123"}, opts)

    assert event.status == "dispatched"
    assert event.source == "test"

    assert [run] = Goals.list_runs(goal.id)
    assert run.event_id == event.id
    assert run.status == "queued"

    execution = Executions.get_execution!(run.execution_id)
    assert %Execution{} = execution
    assert execution.goal_id == goal.id
    assert execution.trigger_kind == "goal:incident.created"
    assert execution.status == "queued"

    assert {:ok, duplicate_event} =
             Goals.trigger(goal.id, "incident.created", %{"id" => "INC-123"}, opts)

    assert duplicate_event.id == event.id
    assert [^event] = Goals.list_events(goal.id)
    assert [^run] = Goals.list_runs(goal.id)
  end

  test "verifies a terminal execution and completes a one-shot goal" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "one-shot-resolution",
               objective: "Resolve one incident",
               goal_type: "one_shot",
               success_criteria: %{"type" => "result_contains", "value" => "resolved"}
             })

    assert {:ok, event} =
             Goals.trigger(goal.id, "incident.closed", %{},
               async: false,
               execution_async: false,
               start_immediately: false
             )

    assert %GoalEvent{} = event
    assert [run] = Goals.list_runs(goal.id)
    execution = Executions.get_execution!(run.execution_id)

    assert {:ok, completed} =
             Executions.complete_execution(execution.id, %{
               task: execution.task,
               session_id: execution.session_id,
               result: "incident resolved",
               execution_history: []
             })

    assert completed.status == "succeeded"
    assert %GoalRun{status: "succeeded"} = completed_run = Goals.get_run(run.id)
    assert completed_run.verification_result["passed"]

    updated_goal = Goals.get_goal!(goal.id)
    assert updated_goal.status == "succeeded"
    assert %DateTime{} = updated_goal.completed_at
    assert is_nil(updated_goal.last_error)
  end

  test "marks the run and goal failed when verification fails" do
    assert {:ok, goal} =
             Goals.create_goal(%{
               name: "failed-verification",
               objective: "Produce a resolved result",
               goal_type: "one_shot",
               success_criteria: %{"type" => "result_contains", "value" => "resolved"}
             })

    assert {:ok, _event} =
             Goals.trigger(goal.id, "work.completed", %{},
               async: false,
               execution_async: false,
               start_immediately: false
             )

    assert [run] = Goals.list_runs(goal.id)
    execution = Executions.get_execution!(run.execution_id)

    assert {:ok, _completed} =
             Executions.complete_execution(execution.id, %{
               task: execution.task,
               session_id: execution.session_id,
               result: "still investigating",
               execution_history: []
             })

    assert %GoalRun{status: "failed"} = failed_run = Goals.get_run(run.id)
    refute failed_run.verification_result["passed"]

    updated_goal = Goals.get_goal!(goal.id)
    assert updated_goal.status == "failed"
    assert updated_goal.last_error == "execution result did not contain expected text"
  end
end
