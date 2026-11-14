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

  test "returns registry health summary", %{conn: conn} do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    tools
    |> Enum.map(&Map.put(&1, "server_id", "internal"))
    |> Tools.sync_registry()

    Tools.update_registry_entry("internal", "read_file", %{health_status: "unavailable"})

    conn = get(conn, "/api/v1/tools/registry/health")
    response = json_response(conn, 200)

    assert %{
             "data" => %{"healthy" => healthy, "unavailable" => unavailable, "tools" => tool_list}
           } =
             response

    assert unavailable >= 1
    assert is_integer(healthy)
    assert is_list(tool_list)

    assert Enum.any?(
             tool_list,
             &(&1["tool_name"] == "read_file" and &1["health_status"] == "unavailable")
           )
  end
end
