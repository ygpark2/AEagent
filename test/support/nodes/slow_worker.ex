defmodule AOS.Test.Support.Nodes.SlowWorker do
  @behaviour AOS.AgentOS.Core.Node

  @impl true
  def run(context, _opts) do
    Process.sleep(Map.get(context, :sleep_ms, 50))
    {:ok, Map.put(context, :last_outcome, :success)}
  end
end
