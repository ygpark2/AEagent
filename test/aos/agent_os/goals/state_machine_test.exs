defmodule AOS.AgentOS.Goals.StateMachineTest do
  use ExUnit.Case, async: true

  alias AOS.AgentOS.Goals.StateMachine

  test "allows the supported lifecycle transitions" do
    assert :ok == StateMachine.transition("draft", "active")
    assert :ok == StateMachine.transition("active", "paused")
    assert :ok == StateMachine.transition("paused", "active")
    assert :ok == StateMachine.transition("active", "succeeded")
    assert :ok == StateMachine.transition("active", "failed")
    assert :ok == StateMachine.transition("active", "cancelled")
    assert :ok == StateMachine.transition("active", "expired")
  end

  test "allows idempotent transitions" do
    assert :ok == StateMachine.transition("active", "active")
    assert :ok == StateMachine.transition("succeeded", "succeeded")
  end

  test "rejects unsupported lifecycle transitions" do
    assert {:error, {:invalid_goal_status_transition, "succeeded", "running"}} =
             StateMachine.transition("succeeded", "running")

    assert {:error, {:invalid_goal_status_transition, "cancelled", "active"}} =
             StateMachine.transition("cancelled", "active")
  end
end
