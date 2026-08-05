defmodule AOS.AgentOS.Goals.StateMachine do
  @moduledoc "Explicit lifecycle transitions for durable Goals."

  @transitions %{
    "draft" => ~w(active cancelled),
    "active" => ~w(paused waiting blocked succeeded failed cancelled expired),
    "paused" => ~w(active cancelled),
    "waiting" => ~w(active blocked failed cancelled),
    "blocked" => ~w(active waiting failed cancelled),
    "succeeded" => ~w(active cancelled),
    "failed" => ~w(active cancelled),
    "cancelled" => [],
    "expired" => []
  }

  def transition(current, next) when current == next, do: :ok

  def transition(current, next) do
    if next in Map.get(@transitions, current, []) do
      :ok
    else
      {:error, {:invalid_goal_status_transition, current, next}}
    end
  end
end
