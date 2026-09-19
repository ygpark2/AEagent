defmodule AOS.AgentOS.AutonomyTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Autonomy
  alias AOS.AgentOS.Tools

  test "read_only blocks confirmed tools" do
    metadata = Tools.metadata_for("internal", "write_file")
    refute Autonomy.tool_allowed?("read_only", metadata)
  end

  test "autonomous auto-approves confirmed tools" do
    metadata = Tools.metadata_for("internal", "execute_command")
    assert Autonomy.tool_allowed?("autonomous", metadata)
    assert Autonomy.auto_approve_tool?("autonomous", metadata)
  end
end
