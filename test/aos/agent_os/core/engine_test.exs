defmodule AOS.AgentOS.Core.EngineTest do
  use AOS.DataCase, async: true
  alias AOS.AgentOS.Core.{Engine, Graph}
  alias AOS.Test.Support.Nodes.{MockEvaluator, MockWorker}

  describe "Agent Graph Engine" do
    test "successfully executes a simple graph and persists to DB" do
      before_count = Repo.one(from e in "agent_executions", select: count(e.id))

      # 1. Build a simple Graph
      graph =
        Graph.new(:test_simple)
        |> Graph.add_node(:worker, MockWorker)
        |> Graph.add_node(:evaluator, MockEvaluator)
        |> Graph.set_initial(:worker)
        |> Graph.add_transition(:worker, :success, :evaluator)
        # End
        |> Graph.add_transition(:evaluator, :pass, nil)

      # 2. Run it
      context = %{task: "Simple Task", force_fail: false}
      assert {:ok, final_context} = Engine.run(graph, context)

      # 3. Check execution history
      history = final_context.execution_history
      assert length(history) == 2
      assert Enum.at(history, 0).node_id == :worker
      assert Enum.at(history, 1).node_id == :evaluator

      # 4. Check DB Persistence (Long-term Memory)
      assert Repo.one(from e in "agent_executions", select: count(e.id)) == before_count + 1
    end

    test "handles loops (Outcome-driven refinement)" do
      # 1. Build a Graph with a loop
      graph =
        Graph.new(:test_loop)
        |> Graph.add_node(:worker, MockWorker)
        |> Graph.add_node(:evaluator, MockEvaluator)
        |> Graph.set_initial(:worker)
        |> Graph.add_transition(:worker, :success, :evaluator)
        # The loop
        |> Graph.add_transition(:evaluator, :fail, :worker)
        |> Graph.add_transition(:evaluator, :pass, nil)

      # 2. Run it with force_fail set to true initially
      context = %{task: "Loop Task", force_fail: true}
      assert {:ok, final_context} = Engine.run(graph, context)

      # 3. Verify loop execution history
      # Expected path: worker -> evaluator (fail) -> worker -> evaluator (pass)
      history = final_context.execution_history
      assert length(history) == 4
      assert Enum.at(history, 1).outcome == :fail
      assert Enum.at(history, 3).outcome == :pass
    end

    test "marks execution failed when the graph points to a missing node" do
      graph =
        Graph.new(:test_missing_node)
        |> Graph.set_initial(:missing)

      assert {:error, :missing, "Node missing not found in graph", context} =
               Engine.run(graph, %{task: "Broken graph"})

      execution = Repo.get!(AOS.AgentOS.Core.Execution, context.execution_id)

      assert execution.status == "failed"
      assert execution.error_message == "Node missing not found in graph"
    end
  end
end
