defmodule AOS.AgentOS.Orchestration.DAGEngineTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Core.Graph
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Orchestration.{DAGEngine, DAGStore, NodeDispatcher}
  alias AOS.AgentOS.ToolUse.ApprovalQueue
  alias AOS.Test.Support.Nodes.{MockWorker, RetryWorker, SlowWorker}

  defmodule GatedWorker do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      if Map.has_key?(context, :approval_decision) or Map.has_key?(context, :approval_request) do
        {:ok,
         context
         |> Map.put(:last_outcome, :success)
         |> Map.put(:result, "gated_success")}
      else
        {:error,
         {:approval_required,
          %{
            tool_name: "high_risk_tool",
            server_id: "internal",
            arguments: %{"action" => "deploy"}
          }}}
      end
    end
  end

  defmodule StartWorker do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      {:ok,
       context
       |> Map.put(:last_outcome, :success)
       |> Map.put(:result, "start_output")
       |> Map.put(:intermediate_data, "preserved_value")}
    end
  end

  defmodule DiamondWorkerA do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      {:ok,
       context
       |> Map.put(:last_outcome, :success)
       |> Map.put(:result, "start_res")}
    end
  end

  defmodule DiamondWorkerB do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      {:ok,
       context
       |> Map.put(:last_outcome, :success)
       |> Map.put(:result, "res_b")
       |> Map.put(:artifacts, ["art_b"])
       |> Map.put(:branch_b_data, "data_from_b")}
    end
  end

  defmodule DiamondWorkerC do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      {:ok,
       context
       |> Map.put(:last_outcome, :success)
       |> Map.put(:result, "res_c")
       |> Map.put(:artifacts, ["art_c"])
       |> Map.put(:branch_c_data, "data_from_c")}
    end
  end

  defmodule DiamondWorkerD do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      if pid = Map.get(context, :test_pid) do
        send(pid, {:diamond_d_received, context})
      end

      {:ok,
       context
       |> Map.put(:last_outcome, :success)
       |> Map.put(:result, "join_completed")}
    end
  end

  defmodule EmptyWorker do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      {:ok, context |> Map.put(:last_outcome, :success)}
    end
  end

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

  test "suspends on approval_required and resumes seamlessly upon ApprovalQueue.approve/2 without restarting prior nodes" do
    graph =
      Graph.new(:approval_suspension_test)
      |> Graph.add_node(:start, StartWorker)
      |> Graph.add_node(:gate, GatedWorker)
      |> Graph.add_node(:finish, MockWorker)
      |> Graph.set_initial(:start)
      |> Graph.add_transition(:start, :success, :gate)
      |> Graph.add_transition(:gate, :success, :finish)
      |> Graph.add_transition(:finish, :success, nil)

    assert {:error, :dag, {:approval_required, _req}, suspended_context} =
             DAGEngine.run(graph, %{task: "run with approval"})

    # Verify DAGRun and Execution are suspended
    dag_run = DAGStore.get_run_by_execution(suspended_context.execution_id)
    assert dag_run.status == "suspended"

    execution = Executions.get_execution!(suspended_context.execution_id)
    assert execution.status == "suspended"

    # Verify node statuses in DAGStore: start succeeded, gate suspended, finish pending
    start_node = DAGStore.get_node(dag_run.id, :start)
    assert start_node.status == "succeeded"
    assert start_node.attempt == 1
    assert start_node.output["result"] == "start_output"

    gate_node = DAGStore.get_node(dag_run.id, :gate)
    assert gate_node.status == "suspended"
    assert gate_node.outcome == "approval_required"

    finish_node = DAGStore.get_node(dag_run.id, :finish)
    assert finish_node.status == "pending"

    # Verify ApprovalRequest was created and is pending
    pending_approvals = ApprovalQueue.list_pending()
    assert Enum.any?(pending_approvals, &(&1.execution_id == execution.id))
    approval = Enum.find(pending_approvals, &(&1.execution_id == execution.id))
    assert approval.tool_name == "high_risk_tool"
    assert approval.status == "pending"

    # Now approve via ApprovalQueue.approve/2 with synchronous execution
    assert {:ok, approved_req} =
             ApprovalQueue.approve(approval.id, %{
               decided_by: "test_operator",
               decision_reason: "verified safe",
               async: false
             })

    assert approved_req.status == "approved"

    # Verify execution finished successfully
    resumed_run = DAGStore.get_run(dag_run.id)
    assert resumed_run.status == "succeeded"

    resumed_execution = Executions.get_execution!(execution.id)
    assert resumed_execution.status == "succeeded"

    # Verify start node was NEVER re-executed (attempt remains 1)
    resumed_start = DAGStore.get_node(dag_run.id, :start)
    assert resumed_start.status == "succeeded"
    assert resumed_start.attempt == 1

    # Verify gate and finish nodes both succeeded
    resumed_gate = DAGStore.get_node(dag_run.id, :gate)
    assert resumed_gate.status == "succeeded"

    resumed_finish = DAGStore.get_node(dag_run.id, :finish)
    assert resumed_finish.status == "succeeded"

    # Verify custom intermediate data was preserved across resumption
    assert resumed_run.result["intermediate_data"] == "preserved_value"

    # Verify timeline recorded suspension and resumption events
    events = DAGStore.list_events(dag_run.id, 100) |> Enum.map(& &1.event_type)
    assert "node.suspended" in events
    assert "orchestration.suspended" in events
    assert "orchestration.completed" in events
  end

  test "rejecting approval marks suspended DAGRun cancelled and Execution failed without wiping execution task/domain" do
    graph =
      Graph.new(:approval_rejection_test)
      |> Graph.add_node(:start, MockWorker)
      |> Graph.add_node(:gate, GatedWorker)
      |> Graph.set_initial(:start)
      |> Graph.add_transition(:start, :success, :gate)
      |> Graph.add_transition(:gate, :success, nil)

    assert {:error, :dag, {:approval_required, _req}, context} =
             DAGEngine.run(graph, %{task: "run to reject"})

    dag_run = DAGStore.get_run_by_execution(context.execution_id)
    assert dag_run.status == "suspended"

    pending =
      ApprovalQueue.list_pending() |> Enum.find(&(&1.execution_id == context.execution_id))

    assert pending != nil

    assert {:ok, rejected} =
             ApprovalQueue.reject(pending.id, %{
               decided_by: "safety_officer",
               decision_reason: "denied due to policy"
             })

    assert rejected.status == "rejected"

    # Verify DAGRun transitioned to cancelled
    cancelled_run = DAGStore.get_run(dag_run.id)
    assert cancelled_run.status == "cancelled"
    assert cancelled_run.error_message == "approval_rejected"

    # Verify pending/ready nodes are also cancelled
    gate_node = DAGStore.get_node(dag_run.id, :gate)
    assert gate_node.status == "cancelled"

    # Verify orchestration.cancelled event was emitted
    events = DAGStore.list_events(dag_run.id, 100) |> Enum.map(& &1.event_type)
    assert "orchestration.cancelled" in events

    # Verify Execution is marked terminal and task/domain are preserved
    terminal_execution = Executions.get_execution!(context.execution_id)
    assert terminal_execution.status in ~w(failed cancelled blocked)
    assert terminal_execution.task == "run to reject"
    assert terminal_execution.domain == "general"

    # Verify redundant rejection returns error tuple
    assert {:error, "approval request already decided"} =
             ApprovalQueue.reject(pending.id)

    # Verify redundant approval returns error tuple
    assert {:error, "approval request already decided"} =
             ApprovalQueue.approve(pending.id)
  end

  test "resume/2 returns error if DAG is already running" do
    graph =
      Graph.new(:already_running_test)
      |> Graph.add_node(:start, SlowWorker)
      |> Graph.set_initial(:start)
      |> Graph.add_transition(:start, :success, nil)

    task = Task.async(fn -> DAGEngine.run(graph, %{task: "slow run", sleep_ms: 1_000}) end)
    Process.sleep(50)

    runs = DAGStore.list_runs(limit: 5)
    running_run = Enum.find(runs, &(&1.status in ~w(running queued)))
    assert running_run != nil

    assert {:error, {:dag_already_running, run_id, status}} = DAGEngine.resume(running_run.id)
    assert run_id == running_run.id
    assert status in ~w(running queued)

    Task.await(task, 5_000)
  end

  test "non-approval blocking reasons remain terminal :blocked and do not suspend" do
    defmodule OutOfBudgetWorker do
      @behaviour AOS.AgentOS.Core.Node
      def run(_context, _opts), do: {:error, :out_of_budget}
    end

    graph =
      Graph.new(:blocked_test)
      |> Graph.add_node(:start, OutOfBudgetWorker)
      |> Graph.set_initial(:start)
      |> Graph.add_transition(:start, :success, nil)

    assert {:error, :dag, :out_of_budget, context} =
             DAGEngine.run(graph, %{task: "budget breach"})

    dag_run = DAGStore.get_run_by_execution(context.execution_id)
    assert dag_run.status == "blocked"

    execution = Executions.get_execution!(context.execution_id)
    assert execution.status == "blocked"

    # Verify no approval request was enqueued
    assert Enum.empty?(
             ApprovalQueue.list_requests(status: "pending")
             |> Enum.filter(&(&1.execution_id == execution.id))
           )
  end

  test "namespaced parallel fan-in merging preserves node outputs, artifacts, and prevents overwriting in diamond DAG (A -> B, C -> D)" do
    test_pid = self()

    graph =
      Graph.new(:diamond_dag)
      |> Graph.add_node(:a, DiamondWorkerA)
      |> Graph.add_node(:b, DiamondWorkerB)
      |> Graph.add_node(:c, DiamondWorkerC)
      |> Graph.add_node(:d, DiamondWorkerD)
      |> Graph.set_initial(:a)
      |> Graph.add_transition(:a, :success, :b)
      |> Graph.add_transition(:a, :success, :c)
      |> Graph.add_transition(:b, :success, :d)
      |> Graph.add_transition(:c, :success, :d)
      |> Graph.add_transition(:d, :success, nil)

    assert {:ok, final_context} =
             DAGEngine.run(graph, %{task: "diamond merge", test_pid: test_pid})

    assert_receive {:diamond_d_received, join_context}

    # Acceptance Criteria: D receives artifacts: [art_b, art_c] and node_outputs: %{"b" => ..., "c" => ...}
    assert join_context.artifacts == ["art_b", "art_c"]
    assert Map.has_key?(join_context.node_outputs, "b")
    assert Map.has_key?(join_context.node_outputs, "c")

    # Verify B and C outputs are intact under node_outputs without collision
    assert join_context.node_outputs["b"][:result] == "res_b"
    assert join_context.node_outputs["b"][:artifacts] == ["art_b"]
    assert join_context.node_outputs["b"][:branch_b_data] == "data_from_b"

    assert join_context.node_outputs["c"][:result] == "res_c"
    assert join_context.node_outputs["c"][:artifacts] == ["art_c"]
    assert join_context.node_outputs["c"][:branch_c_data] == "data_from_c"

    # Multi-branch result clash: inputs contains both branches
    assert join_context.inputs["b"]["result"] == "res_b"
    assert join_context.inputs["c"]["result"] == "res_c"

    # Non-colliding keys from parallel branches are preserved in merged context
    assert join_context.branch_b_data == "data_from_b"
    assert join_context.branch_c_data == "data_from_c"

    # Verify final_context also retains concatenated artifacts and preserved node_outputs
    assert final_context.artifacts == ["art_b", "art_c"]
    assert final_context.node_outputs["b"][:result] == "res_b"
    assert final_context.node_outputs["c"][:result] == "res_c"
    assert final_context.node_outputs["d"][:result] == "join_completed"
    assert final_context.result == "join_completed"
  end

  test "parallel fan-in safely handles empty or nil predecessor outputs without crashing" do
    test_pid = self()

    graph =
      Graph.new(:empty_branch_dag)
      |> Graph.add_node(:a, DiamondWorkerA)
      |> Graph.add_node(:b, EmptyWorker)
      |> Graph.add_node(:c, DiamondWorkerC)
      |> Graph.add_node(:d, DiamondWorkerD)
      |> Graph.set_initial(:a)
      |> Graph.add_transition(:a, :success, :b)
      |> Graph.add_transition(:a, :success, :c)
      |> Graph.add_transition(:b, :success, :d)
      |> Graph.add_transition(:c, :success, :d)
      |> Graph.add_transition(:d, :success, nil)

    assert {:ok, final_context} =
             DAGEngine.run(graph, %{task: "empty branch test", test_pid: test_pid})

    assert_receive {:diamond_d_received, join_context}

    assert join_context.artifacts == ["art_c"]
    assert join_context.node_outputs["c"][:result] == "res_c"
    assert final_context.artifacts == ["art_c"]
  end
end
