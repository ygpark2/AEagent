defmodule AOS.AgentOS.Execution.StateMachine do
  @moduledoc """
  Explicit execution status transition rules.
  """

  @transitions %{
    "queued" => ~w(running succeeded blocked failed suspended cancelled timed_out),
    "running" => ~w(succeeded blocked failed suspended cancelled timed_out),
    "suspended" => ~w(running queued failed blocked cancelled succeeded timed_out),
    "blocked" => ~w(queued running cancelled),
    "failed" => ~w(queued running),
    "cancelled" => ~w(queued),
    "timed_out" => ~w(queued running),
    "succeeded" => []
  }

  def terminal_statuses, do: ~w(succeeded failed blocked timed_out)

  def transition(current, next) when current == next, do: :ok

  def transition(current, next) do
    if next in Map.get(@transitions, current, []) do
      :ok
    else
      {:error, {:invalid_status_transition, current, next}}
    end
  end
end
