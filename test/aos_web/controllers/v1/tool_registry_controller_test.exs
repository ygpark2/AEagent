defmodule AOSWeb.V1.ToolRegistryControllerTest do
  use AOSWeb.ConnCase, async: true

  alias AOS.AgentOS.MCP.Internal.Shell
  alias AOS.AgentOS.Tools

  setup %{conn: conn} do
    {:ok, conn: conn |> put_req_header("accept", "application/json") |> put_api_auth()}
  end

  test "rejects unauthenticated registry API requests" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/v1/tools/registry")

    assert %{"errors" => [%{"detail" => "unauthorized"}]} = json_response(conn, 401)
  end

  test "syncs and lists tool registry entries", %{conn: conn} do
    conn = post(conn, "/api/v1/tools/registry/sync")

    assert %{"data" => %{"synced" => synced}} = json_response(conn, 200)
    assert synced >= 1

    conn = get(recycle(conn) |> put_api_auth(), "/api/v1/tools/registry")

    assert %{"data" => entries} = json_response(conn, 200)
    assert Enum.any?(entries, &(&1["server_id"] == "internal" and &1["tool_name"] == "read_file"))
  end

  test "updates registry entry policy fields", %{conn: conn} do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    tools
    |> Enum.map(&Map.put(&1, "server_id", "internal"))
    |> Tools.sync_registry()

    conn =
      patch(conn, "/api/v1/tools/registry/internal/read_file", %{
        risk_tier: "high",
        requires_confirmation: true,
        enabled: false
      })

    assert %{
             "data" => %{
               "server_id" => "internal",
               "tool_name" => "read_file",
               "risk_tier" => "high",
               "requires_confirmation" => true,
               "enabled" => false
             }
           } = json_response(conn, 202)
  end
end
