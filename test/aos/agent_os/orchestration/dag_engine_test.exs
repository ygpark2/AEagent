defmodule AOS.AgentOS.Orchestration.DAGEngineTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Core.{Graph}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Orchestration.{DAGEngine, DAGStore, NodeDispatcher}
  alias AOS.Test.Support.Nodes.{MockWorker, RetryWorker, SlowWorker}

  test "executes fan-out/fan-in DAGs with a durable join barrier" do
    graph =
      Graph.new(:fanout_fanin)
      |> Graph.add_node(:start, MockWorker)
      |> Graph.add_node(:left, MockWorker)
      |> Graph.add_node(:right, MockWorker)
      |> Graph.add_node(:join, MockWorker)
      |> Graph.set_initial(:start)
      |> Graph.add_transition(:start, :success, :left)
      |> Graph.add_transition(:start, :success, :right)
      |> Graph.add_transition(:left, :success, :join)
      |> Graph.add_transition(:right, :success, :join)
      |> Graph.add_transition(:join, :success, nil)

    assert {:ok, context} = DAGEngine.run(graph, %{task: "fan out"})
    assert Enum.map(context.execution_history, & &1.node_id) == ["start", "left", "right", "join"]

    run = DAGStore.get_run_by_execution(context.execution_id)
    assert run.status == "succeeded"

    nodes = DAGStore.list_nodes(run.id)
    assert Enum.all?(nodes, &(&1.status == "succeeded"))

    event_types = DAGStore.list_events(run.id, 200) |> Enum.map(& &1.event_type)
    assert "join.released" in event_types
    assert "orchestration.completed" in event_types
  end

  test "retries a failed node and preserves idempotent terminal runs" do
    assert {:ok, %{result: "retried"}, 2} =
             NodeDispatcher.run_node("retry", RetryWorker, %{task: "retry"},
               max_attempts: 2,
               timeout_ms: 1_000,
               policy_check: fn context, _node_id -> {:ok, context} end
             )

    assert {:error, :node_timeout, _context, 1} =
             NodeDispatcher.run_node("slow", SlowWorker, %{sleep_ms: 100},
               timeout_ms: 10,
               policy_check: fn context, _node_id -> {:ok, context} end
             )

    test_pid = self()
    spawn(fn -> Process.sleep(10) && send(test_pid, :cancel_node) end)

    assert {:cancelled, _context, 1} =
             NodeDispatcher.run_node("cancel", SlowWorker, %{sleep_ms: 500},
               timeout_ms: 1_000,
               policy_check: fn context, _node_id -> {:ok, context} end,
               cancel_check: fn ->
                 receive do
                   :cancel_node -> true
                 after
                   0 -> false
                 end
               end
             )

    graph =
      Graph.new(:idempotent_dag)
      |> Graph.add_node(:worker, MockWorker)
      |> Graph.set_initial(:worker)
      |> Graph.add_transition(:worker, :success, nil)

    assert {:ok, first} = DAGEngine.run(graph, %{task: "once"}, idempotency_key: "test-once")
    assert {:ok, second} = DAGEngine.run(graph, %{task: "once"}, idempotency_key: "test-once")
    assert first.execution_id == second.execution_id
    assert DAGStore.get_run_by_idempotency("test-once").status == "succeeded"
  end

  test "feature flag selects DAG while explicit graph remains available" do
    previous = Application.get_env(:aos, :dag_engine_enabled)
    Application.put_env(:aos, :dag_engine_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aos, :dag_engine_enabled),
        else: Application.put_env(:aos, :dag_engine_enabled, previous)
    end)

    assert {:ok, dag_execution} =
             Executions.enqueue("dag flagged", start_immediately: false)

    assert dag_execution.engine == "dag"

    assert {:ok, graph_execution} =
             Executions.enqueue("graph explicit", start_immediately: false, engine: :graph)

    assert graph_execution.engine == "graph"
  end
end
