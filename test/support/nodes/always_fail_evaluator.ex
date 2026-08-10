defmodule AOS.Test.Support.Nodes.AlwaysFailEvaluator do
  @moduledoc false

  @behaviour AOS.AgentOS.Core.Node

  @impl true
  def run(context, _opts) do
    {:ok,
     context
     |> Map.put(:last_outcome, :fail)
     |> Map.put(:feedback, "The result still does not satisfy the requirements.")}
  end
end
