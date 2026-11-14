defmodule AOSWeb.V1.ApprovalControllerTest do
  use AOSWeb.ConnCase, async: false

  alias AOS.AgentOS.Core.Graph
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Orchestration.{DAGEngine, DAGStore}
  alias AOS.AgentOS.ToolUse.ApprovalQueue
  alias AOS.Test.Support.Nodes.MockWorker

  defmodule ControllerGatedWorker do
    @behaviour AOS.AgentOS.Core.Node

    def run(context, _opts) do
      if Map.has_key?(context, :approval_decision) or Map.has_key?(context, :approval_request) do
        {:ok, Map.put(context, :last_outcome, :success) |> Map.put(:result, "gated_ok")}
      else
        {:error,
         {:approval_required,
          %{
            tool_name: "deploy_prod",
            server_id: "internal",
            arguments: %{"env" => "prod"}
          }}}
      end
    end
  end

  setup %{conn: conn} do
    {:ok, conn: conn |> put_req_header("accept", "application/json") |> put_api_auth()}
  end

  test "rejects unauthenticated approval API requests" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/v1/approvals")

    assert %{"errors" => [%{"detail" => "unauthorized"}]} = json_response(conn, 401)
  end

  test "lists and shows pending approval requests", %{conn: conn} do
    {:ok, execution} = Executions.enqueue("approval listing task", start_immediately: false)
    {:ok, request} = create_request(execution)

    conn = get(conn, "/api/v1/approvals")

    assert %{"data" => approvals} = json_response(conn, 200)
    assert Enum.any?(approvals, &(&1["id"] == request.id))

    conn = get(recycle(conn) |> put_api_auth(), "/api/v1/approvals/#{request.id}")

    assert %{
             "data" => %{
               "id" => request_id,
               "status" => "pending",
               "tool_name" => "write_file"
             }
           } = json_response(conn, 200)

    assert request_id == request.id
  end

  test "approves a request and resumes the blocked execution", %{conn: conn} do
    {:ok, execution} = Executions.enqueue("approval resume task", start_immediately: false)

    {:ok, _blocked} =
      Executions.block_execution(
        execution.id,
        %{task: execution.task, session_id: execution.session_id, execution_history: []},
        {:approval_required, %{id: "request"}}
      )

    {:ok, request} = create_request(execution)

    conn =
      post(conn, "/api/v1/approvals/#{request.id}/approve", %{
        start_immediately: false,
        decided_by: "operator",
        decision_reason: "approved in test"
      })

    assert %{
             "data" => %{
               "approval_request" => %{"status" => "approved"},
               "resumed_execution" => %{
                 "source_execution_id" => source_execution_id,
                 "trigger_kind" => "resume",
                 "status" => "queued"
               }
             }
           } = json_response(conn, 202)

    assert source_execution_id == execution.id
  end

  test "rejects a request without resuming", %{conn: conn} do
    {:ok, execution} = Executions.enqueue("approval reject task", start_immediately: false)
    {:ok, request} = create_request(execution)

    conn =
      post(conn, "/api/v1/approvals/#{request.id}/reject", %{
        decided_by: "operator",
        decision_reason: "too risky"
      })

    assert %{
             "data" => %{
               "approval_request" => %{"status" => "rejected", "decision_reason" => "too risky"}
             }
           } = json_response(conn, 202)
  end

  test "approves a suspended DAG execution and resumes to terminal success", %{conn: conn} do
    graph =
      Graph.new(:controller_dag_approval)
      |> Graph.add_node(:step1, MockWorker)
      |> Graph.add_node(:step2, ControllerGatedWorker)
      |> Graph.add_node(:step3, MockWorker)
      |> Graph.set_initial(:step1)
      |> Graph.add_transition(:step1, :success, :step2)
      |> Graph.add_transition(:step2, :success, :step3)
      |> Graph.add_transition(:step3, :success, nil)

    assert {:error, :dag, {:approval_required, _req}, context} =
             DAGEngine.run(graph, %{task: "dag controller task"})

    dag_run = DAGStore.get_run_by_execution(context.execution_id)
    assert dag_run.status == "suspended"

    pending =
      ApprovalQueue.list_pending() |> Enum.find(&(&1.execution_id == context.execution_id))

    assert pending != nil

    # Approve via API with wait: true so it executes synchronously
    conn =
      post(conn, "/api/v1/approvals/#{pending.id}/approve", %{
        wait: true,
        decided_by: "api_operator",
        decision_reason: "approved via web api"
      })

    assert %{
             "data" => %{
               "approval_request" => %{"status" => "approved"}
             }
           } = json_response(conn, 202)

    # Verify DAG completed to succeeded without restarting step1
    resumed_run = DAGStore.get_run(dag_run.id)
    assert resumed_run.status == "succeeded"

    step1 = DAGStore.get_node(dag_run.id, :step1)
    assert step1.status == "succeeded"
    assert step1.attempt == 1

    step2 = DAGStore.get_node(dag_run.id, :step2)
    assert step2.status == "succeeded"

    step3 = DAGStore.get_node(dag_run.id, :step3)
    assert step3.status == "succeeded"

    # Redundant approval returns 422 with already decided error
    redundant_conn =
      post(recycle(conn) |> put_api_auth(), "/api/v1/approvals/#{pending.id}/approve", %{
        decided_by: "api_operator"
      })

    assert %{"errors" => [%{"title" => "approval request already decided"}]} =
             json_response(redundant_conn, 422)
  end

  test "returns 404 when approving a DAG execution whose DAG run is missing", %{conn: conn} do
    Application.put_env(:aos, :dag_engine_enabled, true)
    on_exit(fn -> Application.delete_env(:aos, :dag_engine_enabled) end)

    {:ok, execution} =
      Executions.enqueue("missing dag task", start_immediately: false, engine: :dag)

    assert execution.engine == "dag"

    {:ok, _suspended} =
      Executions.suspend_execution(
        execution.id,
        %{task: execution.task, session_id: execution.session_id, execution_history: []},
        {:approval_required, %{id: "request"}}
      )

    {:ok, request} = create_request(execution)

    conn =
      post(conn, "/api/v1/approvals/#{request.id}/approve", %{
        wait: true,
        decided_by: "operator"
      })

    assert json_response(conn, 404)
  end

  defp create_request(execution) do
    ApprovalQueue.create_request(%{
      execution_id: execution.id,
      session_id: execution.session_id,
      server_id: "internal",
      tool_name: "write_file",
      arguments: %{"path" => "tmp.txt"},
      risk_tier: "high"
    })
  end
end
