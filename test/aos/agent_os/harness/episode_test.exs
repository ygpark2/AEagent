defmodule AOS.AgentOS.Harness.EpisodeTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Executions

  test "creates one durable episode and task trace per execution" do
    assert {:ok, execution} =
             Executions.enqueue("harness episode task",
               start_immediately: false,
               initial_context: %{harness: %{"budgets" => %{"max_tool_calls" => 4}}}
             )

    episode = Executions.get_harness_episode(execution.id)
    traces = Executions.list_harness_traces(execution.id)

    assert episode.execution_id == execution.id
    assert episode.status == "queued"
    assert episode.budget["max_tool_calls"] == 4
    assert Enum.any?(traces, &(&1.trace_type == "task" and &1.phase == "specified"))
  end
end
