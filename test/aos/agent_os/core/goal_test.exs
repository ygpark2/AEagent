defmodule AOS.AgentOS.Core.GoalTest do
  use ExUnit.Case, async: true

  alias AOS.AgentOS.Core.Goal

  test "accepts a valid goal definition" do
    changeset =
      Goal.changeset(%Goal{}, %{
        name: "monitor-production",
        objective: "Keep the deployed service healthy",
        status: "active",
        goal_type: "ongoing",
        autonomy_level: "supervised"
      })

    assert changeset.valid?
  end

  test "requires the goal identity and lifecycle fields" do
    changeset = Goal.changeset(%Goal{status: nil, goal_type: nil}, %{})

    refute changeset.valid?
    assert %{name: _, objective: _, status: _, goal_type: _} = errors_to_map(changeset)
  end

  test "rejects unsupported status, goal type, autonomy, and version" do
    changeset =
      Goal.changeset(%Goal{}, %{
        name: "invalid-goal",
        objective: "Invalid configuration",
        status: "running",
        goal_type: "recurring",
        autonomy_level: "unrestricted",
        version: 0
      })

    refute changeset.valid?
    errors = errors_to_map(changeset)
    assert errors.status
    assert errors.goal_type
    assert errors.autonomy_level
    assert errors.version
  end

  defp errors_to_map(changeset) do
    Map.new(changeset.errors, fn {field, error} -> {field, error} end)
  end
end
