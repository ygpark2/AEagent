defmodule AOS.AgentOS.Evolution.StrategyMutatorTest do
  use ExUnit.Case, async: true

  alias AOS.AgentOS.Evolution.StrategyMutator

  test "adds an evaluator before reporter for low-quality LLM output" do
    blueprint = %{
      "initial_node" => "thinker",
      "nodes" => %{"thinker" => "thinker", "reporter" => "reporter"},
      "transitions" => [
        %{"from" => "thinker", "on" => "success", "to" => "reporter"},
        %{"from" => "reporter", "on" => "success", "to" => nil}
      ]
    }

    assert {:ok, mutated, "bad_llm_output"} = StrategyMutator.mutate(blueprint, "bad_llm_output")
    assert mutated["nodes"]["critic"] == "critic"
    assert %{"from" => "thinker", "on" => "success", "to" => "critic"} in mutated["transitions"]

    assert %{"from" => "critic", "on" => "pass", "to" => "reporter"} in mutated[
             "transitions"
           ]

    assert %{"from" => "critic", "on" => "fail", "to" => "thinker"} in mutated[
             "transitions"
           ]
  end

  test "simplifies expensive strategies to thinker and reporter when possible" do
    blueprint = %{
      "initial_node" => "thinker",
      "nodes" => %{
        "thinker" => "thinker",
        "critic" => "critic",
        "reporter" => "reporter",
        "delegator" => "delegator"
      },
      "transitions" => []
    }

    assert {:ok, mutated, "budget_exceeded"} =
             StrategyMutator.mutate(blueprint, "budget_exceeded")

    assert mutated["nodes"] == %{"thinker" => "thinker", "reporter" => "reporter"}
    assert mutated["initial_node"] == "thinker"
  end
end
