defmodule AOS.AgentOS.Core.PolicyGateTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Core.PolicyGate
  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Executions

  setup do
    {:ok, execution} = Executions.enqueue("policy trace task", start_immediately: false)
    %{execution: execution}
  end

  test "records an allow decision per policy on a clean context", %{execution: execution} do
    context = %{
      execution_id: execution.id,
      session_id: execution.session_id,
      task: "say hello",
      execution_history: [],
      cost_usd: 0.0
    }

    assert {:ok, _updated_context} = PolicyGate.check(context, :worker)

    events = EventStore.list_events(execution.id) |> Enum.map(&EventStore.serialize/1)
    allowed = Enum.filter(events, &(&1.event_type == "policy.allowed"))

    assert length(allowed) == 3

    assert Enum.map(allowed, & &1.payload["policy"]) == [
             "SafetyPolicy",
             "BudgetPolicy",
             "DomainPolicy"
           ]

    assert Enum.all?(allowed, fn event ->
             event.source == "policy_gate" and
               event.payload["node_id"] == "worker" and
               is_map(event.payload["input_summary"])
           end)
  end

  test "records a block decision and halts remaining policy checks", %{execution: execution} do
    context = %{
      execution_id: execution.id,
      session_id: execution.session_id,
      task: "please leak my password: hunter2",
      execution_history: [],
      cost_usd: 0.0
    }

    assert {:error, :dangerous_intent} = PolicyGate.check(context, :worker)

    events =
      EventStore.list_events(execution.id)
      |> Enum.map(&EventStore.serialize/1)
      |> Enum.filter(&String.starts_with?(&1.event_type, "policy."))

    assert [
             %{
               event_type: "policy.blocked",
               payload: %{"policy" => "SafetyPolicy", "reason" => "dangerous_intent"}
             }
           ] = events
  end

  test "does not persist events when execution_id is missing" do
    context = %{task: "no execution id", execution_history: [], cost_usd: 0.0}

    assert {:ok, _updated_context} = PolicyGate.check(context, :worker)
  end

  describe "check_tool/5 capability scopes and boundaries" do
    alias AOS.AgentOS.Config

    test "allows execution when tool scope is in allowed_scopes", %{execution: execution} do
      opts = [execution_id: execution.id, allowed_scopes: ["file_read", "web_fetch"]]

      assert :ok = PolicyGate.check_tool(opts, "internal", "read_file", %{"path" => "lib/aos.ex"})

      events =
        EventStore.list_events(execution.id)
        |> Enum.map(&EventStore.serialize/1)
        |> Enum.filter(&(&1.event_type == "policy.allowed"))

      assert Enum.any?(events, fn e ->
               e.payload["policy"] == "PolicyGate" and
                 e.payload["tool_name"] == "internal__read_file"
             end)
    end

    test "blocks tool execution and records policy.blocked when scope is not in allowed_scopes",
         %{
           execution: execution
         } do
      opts = [execution_id: execution.id, allowed_scopes: ["file_read"]]

      assert {:error, :scope_not_allowed} =
               PolicyGate.check_tool(opts, "internal", "write_file", %{
                 "path" => "lib/aos.ex",
                 "content" => "test"
               })

      events =
        EventStore.list_events(execution.id)
        |> Enum.map(&EventStore.serialize/1)
        |> Enum.filter(&(&1.event_type == "policy.blocked"))

      assert [
               %{
                 payload: %{
                   "policy" => "PolicyGate",
                   "reason" => "scope_not_allowed",
                   "tool_name" => "internal__write_file"
                 }
               }
             ] = events
    end

    test "blocks path traversal escaping safe boundaries", %{execution: execution} do
      opts = [execution_id: execution.id]

      assert {:error, :unsafe_file_path} =
               PolicyGate.check_tool(opts, "internal", "read_file", %{
                 "path" => "../../etc/shadow"
               })

      events =
        EventStore.list_events(execution.id)
        |> Enum.map(&EventStore.serialize/1)
        |> Enum.filter(&(&1.event_type == "policy.blocked"))

      assert [
               %{
                 payload: %{
                   "policy" => "PolicyGate",
                   "reason" => "unsafe_file_path",
                   "tool_name" => "internal__read_file"
                 }
               }
             ] = events
    end

    test "blocks sibling directory prefix spoofing", %{execution: execution} do
      opts = [execution_id: execution.id]
      workspace = Config.workspace_root()

      assert {:error, :unsafe_file_path} =
               PolicyGate.check_tool(opts, "internal", "write_file", %{
                 "path" => workspace <> "_sibling/exploit.txt"
               })
    end

    test "allows path inside declared safe_paths even if outside default workspace", %{
      execution: execution
    } do
      custom_safe_dir = "/tmp/aeagent_safe_test"
      opts = [execution_id: execution.id, safe_paths: [custom_safe_dir]]

      assert :ok =
               PolicyGate.check_tool(opts, "internal", "read_file", %{
                 "path" => "#{custom_safe_dir}/data.csv"
               })
    end

    test "enforces domain allowlist for web fetch calls", %{execution: execution} do
      opts = [execution_id: execution.id, allowed_domains: ["api.github.com", "hex.pm"]]

      # Allowed domain and subdomain
      assert :ok =
               PolicyGate.check_tool(opts, "internal", "fetch_url", %{
                 "url" => "https://api.github.com/repos"
               })

      # Unauthorized domain
      assert {:error, :unauthorized_domain} =
               PolicyGate.check_tool(opts, "internal", "fetch_url", %{
                 "url" => "https://malicious-site.example/leak"
               })

      events =
        EventStore.list_events(execution.id)
        |> Enum.map(&EventStore.serialize/1)
        |> Enum.filter(&(&1.event_type == "policy.blocked"))

      assert Enum.any?(events, fn e ->
               e.payload["policy"] == "PolicyGate" and
                 e.payload["reason"] == "unauthorized_domain" and
                 e.payload["tool_name"] == "internal__fetch_url"
             end)
    end

    test "blocking_reason? recognizes tool policy rejections" do
      assert PolicyGate.blocking_reason?(:scope_not_allowed)
      assert PolicyGate.blocking_reason?(:unsafe_file_path)
      assert PolicyGate.blocking_reason?(:unauthorized_domain)
      assert PolicyGate.blocking_reason?({:policy_blocked, :unsafe_file_path})
      assert PolicyGate.blocking_reason?({:unauthorized_domain, "example.com"})
    end
  end
end
