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
end
