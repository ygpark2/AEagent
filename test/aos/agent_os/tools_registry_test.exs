defmodule AOS.AgentOS.ToolsRegistryTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.MCP.Internal.Shell
  alias AOS.AgentOS.Tools

  test "syncs MCP tool specs into registry" do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    result =
      tools
      |> Enum.map(&Map.put(&1, "server_id", "internal"))
      |> Tools.sync_registry()

    assert result.ok != []

    entries = Tools.list_registry_entries()
    assert Enum.any?(entries, &(&1.server_id == "internal" and &1.tool_name == "read_file"))
  end

  test "registry metadata overrides static catalog metadata" do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    tools
    |> Enum.map(&Map.put(&1, "server_id", "internal"))
    |> Tools.sync_registry()

    assert {:ok, _entry} =
             Tools.update_registry_entry("internal", "read_file", %{
               risk_tier: "high",
               requires_confirmation: true,
               retryable: true,
               timeout_ms: 10_000
             })

    metadata = Tools.metadata_for("internal", "read_file")
    assert metadata.risk_tier == "high"
    assert metadata.requires_confirmation
    assert metadata.retryable
    assert metadata.timeout_ms == 10_000
  end

  test "disabled registry entries are not exposed as permitted tools" do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    all_tools = Enum.map(tools, &Map.put(&1, "server_id", "internal"))
    Tools.sync_registry(all_tools)

    assert {:ok, _entry} =
             Tools.update_registry_entry("internal", "write_file", %{enabled: false})

    permitted = Tools.permitted_tools(all_tools, [])
    refute Enum.any?(permitted, &(&1["server_id"] == "internal" and &1["name"] == "write_file"))
  end
end
