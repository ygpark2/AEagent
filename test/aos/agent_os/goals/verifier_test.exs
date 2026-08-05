defmodule AOS.AgentOS.Goals.VerifierTest do
  use ExUnit.Case, async: true

  alias AOS.AgentOS.Core.Execution
  alias AOS.AgentOS.Goals.Verifier

  test "passes an execution with the default success criteria" do
    result = Verifier.verify(%{success_criteria: %{}}, execution(%{}))

    assert result.passed
    assert result.details == %{type: "execution_status", status: "succeeded"}
  end

  test "verifies execution status criteria" do
    goal = %{success_criteria: %{"type" => "execution_status", "value" => "succeeded"}}

    assert %{passed: true, details: %{status: "succeeded"}} =
             Verifier.verify(goal, execution(%{status: "succeeded"}))

    assert %{passed: false, details: %{reason: reason}} =
             Verifier.verify(goal, execution(%{status: "failed"}))

    assert reason == "expected execution status succeeded, got failed"
  end

  test "verifies result_contains criteria" do
    goal = %{success_criteria: %{type: "result_contains", value: "resolved"}}

    assert %{passed: true} =
             Verifier.verify(goal, execution(%{final_result: "incident resolved"}))

    assert %{passed: false, details: %{reason: "execution result did not contain expected text"}} =
             Verifier.verify(goal, execution(%{final_result: "incident remains open"}))
  end

  test "requires every criterion in an all group to pass" do
    goal = %{
      success_criteria: %{
        "all" => [
          %{"type" => "execution_status", "value" => "succeeded"},
          %{"type" => "result_contains", "value" => "done"}
        ]
      }
    }

    assert %{passed: true, details: %{type: "all", criteria: [_, _]}} =
             Verifier.verify(goal, execution(%{final_result: "done"}))

    assert %{passed: false, details: %{reason: reason}} =
             Verifier.verify(goal, execution(%{final_result: "not finished"}))

    assert reason == "execution result did not contain expected text"
  end

  test "rejects unsupported or malformed criteria" do
    assert %{passed: false, details: %{reason: "unsupported success criteria"}} =
             Verifier.verify(%{success_criteria: %{"type" => "unknown"}}, execution(%{}))

    assert %{
             passed: false,
             details: %{reason: "result_contains requires a string result and value"}
           } =
             Verifier.verify(
               %{success_criteria: %{"type" => "result_contains", "value" => "done"}},
               execution(%{final_result: nil})
             )
  end

  defp execution(attrs) do
    struct!(
      %Execution{
        status: "succeeded",
        final_result: "done"
      },
      attrs
    )
  end
end
