defmodule AOS.AgentOS.Roles.ExecutorTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Roles.Executor

  setup do
    {:ok, execution} = Executions.enqueue("executor test task", start_immediately: false)
    opts = [execution_id: execution.id, session_id: execution.session_id]
    %{execution: execution, opts: opts}
  end

  test "execute_tool returns {:error, :scope_not_allowed} when capability scope is restricted", %{
    opts: opts
  } do
    restricted_opts = Keyword.put(opts, :allowed_scopes, ["file_read"])

    assert {:error, :scope_not_allowed} =
             Executor.execute_tool(
               "internal",
               "write_file",
               %{
                 "path" => "lib/aos.ex",
                 "content" => "test"
               },
               restricted_opts
             )
  end

  test "execute_tool returns {:error, :unsafe_file_path} on directory traversal", %{opts: opts} do
    assert {:error, :unsafe_file_path} =
             Executor.execute_tool(
               "internal",
               "read_file",
               %{
                 "path" => "../../etc/passwd"
               },
               opts
             )
  end

  test "execute_tool returns {:error, :unauthorized_domain} on unapproved network domain", %{
    opts: opts
  } do
    restricted_opts = Keyword.put(opts, :allowed_domains, ["hex.pm"])

    assert {:error, :unauthorized_domain} =
             Executor.execute_tool(
               "internal",
               "fetch_url",
               %{
                 "url" => "https://attacker.com/payload"
               },
               restricted_opts
             )
  end

  test "run/2 delegates policy options and rejects unsafe operations", %{execution: execution} do
    input = %{
      tool_name: "write_file",
      server_id: "internal",
      args: %{"path" => "../../etc/shadow", "content" => "evil"},
      execution_id: execution.id,
      session_id: execution.session_id
    }

    assert {:error, :unsafe_file_path} = Executor.run(input, %{})
  end
end
