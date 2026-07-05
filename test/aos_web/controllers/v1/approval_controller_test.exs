defmodule AOSWeb.V1.ApprovalControllerTest do
  use AOSWeb.ConnCase, async: true

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.ApprovalQueue

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
