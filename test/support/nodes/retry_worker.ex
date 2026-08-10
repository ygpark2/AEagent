defmodule AOS.Test.Support.Nodes.RetryWorker do
  @behaviour AOS.AgentOS.Core.Node

  @impl true
  def run(context, _opts) do
    if Map.get(context, :node_attempt, 1) >= 2 do
      {:ok, context |> Map.put(:result, "retried") |> Map.put(:last_outcome, :success)}
    else
      {:error, :transient_failure}
    end
  end
end
