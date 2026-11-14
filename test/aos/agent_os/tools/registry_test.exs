defmodule AOS.AgentOS.Tools.RegistryTest do
  use AOS.DataCase, async: false

  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.MCP.Internal.Shell
  alias AOS.AgentOS.Roles.Executor
  alias AOS.AgentOS.Tools
  alias AOS.AgentOS.Tools.Registry

  setup do
    {:ok, %{"tools" => tools}} = Shell.list_tools()

    tools
    |> Enum.map(&Map.put(&1, "server_id", "internal"))
    |> Tools.sync_registry()

    :ok
  end

  test "single tool failure increments consecutive_failures and status remains healthy" do
    assert {:ok, entry} =
             Tools.record_tool_result("internal", "read_file", {:error, "Connection timeout"})

    assert entry.health_status == "healthy"
    assert entry.metadata["consecutive_failures"] == 1
    assert Tools.tool_available?("internal", "read_file")
  end

  test "3 consecutive failures trip circuit breaker to unavailable and emit event" do
    assert {:ok, _} = Tools.record_tool_result("internal", "read_file", {:error, "Error 1"})
    assert {:ok, _} = Tools.record_tool_result("internal", "read_file", {:error, "Error 2"})
    assert {:ok, entry} = Tools.record_tool_result("internal", "read_file", {:error, "Error 3"})

    assert entry.health_status == "unavailable"
    assert entry.metadata["consecutive_failures"] == 3
    refute Tools.tool_available?("internal", "read_file")

    # Check that event was emitted to EventStore
    events = EventStore.list_events(nil)
    tripped_event = Enum.find(events, &(&1.event_type == "tool.circuit_breaker.tripped"))
    assert tripped_event != nil
    assert tripped_event.payload["tool_name"] == "read_file"
    assert tripped_event.payload["server_id"] == "internal"
    assert tripped_event.payload["consecutive_failures"] == 3
  end

  test "successful tool execution resets consecutive_failures and restores healthy status" do
    # Trip the breaker first
    for i <- 1..3 do
      Tools.record_tool_result("internal", "read_file", {:error, "Error #{i}"})
    end

    refute Tools.tool_available?("internal", "read_file")

    # Now record success
    assert {:ok, entry} = Tools.record_tool_result("internal", "read_file", {:ok, "Success"})
    assert entry.health_status == "healthy"
    assert entry.metadata["consecutive_failures"] == 0
    assert Tools.tool_available?("internal", "read_file")
  end

  test "operator manual update to healthy resets consecutive_failures" do
    for i <- 1..3 do
      Tools.record_tool_result("internal", "read_file", {:error, "Error #{i}"})
    end

    refute Tools.tool_available?("internal", "read_file")

    # Operator marks healthy
    assert {:ok, entry} =
             Tools.update_registry_entry("internal", "read_file", %{health_status: "healthy"})

    assert entry.health_status == "healthy"
    assert entry.metadata["consecutive_failures"] == 0
    assert Tools.tool_available?("internal", "read_file")
  end

  test "dispatching to unavailable tool via Executor halts with {:error, :tool_unavailable}" do
    # Trip breaker
    for i <- 1..3 do
      Tools.record_tool_result("internal", "read_file", {:error, "Error #{i}"})
    end

    refute Tools.tool_available?("internal", "read_file")

    # Direct execution attempt halts before MCP call
    assert {:error, :tool_unavailable} =
             Executor.execute_tool("internal", "read_file", %{"path" => "README.md"})

    # Via Executor.run
    assert {:error, :tool_unavailable} =
             Executor.run(
               %{tool_name: "read_file", server_id: "internal", args: %{"path" => "README.md"}},
               %{}
             )
  end

  test "health_summary returns counts and tool list" do
    # Initially all synced tools should be healthy
    summary = Registry.health_summary()
    assert summary.healthy >= 1
    assert summary.unavailable == 0
    assert is_list(summary.tools)

    # Trip one tool
    for i <- 1..3 do
      Tools.record_tool_result("internal", "read_file", {:error, "Error #{i}"})
    end

    updated_summary = Registry.health_summary()
    assert updated_summary.unavailable == 1
    assert updated_summary.summary.unavailable == 1
  end
end
