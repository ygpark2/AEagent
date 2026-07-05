defmodule AOS.AgentOS.Evolution.StrategyLifecycle do
  @moduledoc """
  Write-side lifecycle policies for evolved strategies.
  """

  import Ecto.Query

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Evolution.{Fitness, Strategy, StrategyEvents}
  alias AOS.Repo

  def mark_used(nil), do: :ok

  def mark_used(strategy_id) do
    now = DateTime.utc_now()

    Strategy
    |> where([s], s.id == ^strategy_id)
    |> Repo.update_all(inc: [usage_count: 1], set: [last_used_at: now])

    :ok
  end

  def record_outcome(nil, _status, _context, _reason), do: :ok

  def record_outcome(strategy_id, status, context, reason) do
    case Repo.get(Strategy, strategy_id) do
      nil -> :ok
      strategy -> update_outcome(strategy, status, context, reason)
    end
  end

  def prune(opts \\ []) do
    min_usage = Keyword.get(opts, :min_usage, Config.evolution_archive_min_usage())
    min_success_rate = Keyword.get(opts, :success_rate, Config.evolution_archive_success_rate())
    now = DateTime.utc_now()

    Strategy
    |> where([s], s.status in ["active", "experimental"])
    |> where([s], s.usage_count >= ^min_usage)
    |> Repo.all()
    |> Enum.filter(&(success_rate(&1) < min_success_rate))
    |> Enum.reduce(%{archived: 0}, &archive_strategy(&1, &2, now, min_usage, min_success_rate))
  end

  defp update_outcome(strategy, status, context, reason) do
    score = Fitness.score(status, context, reason)
    next_fitness = next_fitness(strategy, score)
    next_status = next_status(strategy, status, next_fitness)

    strategy
    |> Strategy.changeset(
      outcome_attrs(strategy, status, context, reason, next_fitness, next_status)
    )
    |> Repo.update()
    |> case do
      {:ok, updated} = result ->
        record_outcome_event(updated, status, context, next_fitness, next_status)
        maybe_record_promotion(strategy, updated)
        maybe_deprecate_parent(strategy, updated.status, next_fitness)
        result

      error ->
        error
    end
  end

  defp record_outcome_event(updated, status, context, next_fitness, next_status) do
    StrategyEvents.create(
      updated,
      "outcome",
      status,
      outcome_event(context, reason_from_status(status), next_fitness)
    )

    if next_status == "archived" do
      StrategyEvents.create(updated, "archived", "experimental_failure", %{
        "fitness_score" => next_fitness,
        "reason" => status
      })
    end
  end

  defp reason_from_status("succeeded"), do: nil
  defp reason_from_status(status), do: status

  defp outcome_attrs(strategy, status, context, reason, next_fitness, next_status) do
    %{
      status: next_status,
      promoted_at: promoted_at(strategy, status, next_fitness),
      archived_at:
        if(next_status == "archived", do: DateTime.utc_now(), else: strategy.archived_at),
      fitness_score: next_fitness,
      success_count: strategy.success_count + success_increment(status),
      failure_count: strategy.failure_count + failure_increment(status),
      metadata:
        Map.merge(strategy.metadata || %{}, %{
          "last_failure_category" => Fitness.failure_category(reason),
          "last_quality_score" => Map.get(context, :evaluation_score),
          "last_execution_duration_ms" => Map.get(context, :execution_duration_ms)
        })
    }
  end

  defp outcome_event(context, reason, next_fitness) do
    %{
      "fitness_score" => next_fitness,
      "quality_score" => Map.get(context, :evaluation_score),
      "failure_category" => Fitness.failure_category(reason),
      "execution_duration_ms" => Map.get(context, :execution_duration_ms)
    }
  end

  defp archive_strategy(strategy, acc, now, min_usage, min_success_rate) do
    strategy
    |> Strategy.changeset(%{status: "archived", archived_at: now})
    |> Repo.update()
    |> case do
      {:ok, archived} ->
        StrategyEvents.create(archived, "archived", "low_success_rate", %{
          "success_rate" => success_rate(strategy),
          "min_success_rate" => min_success_rate,
          "min_usage" => min_usage
        })

        Map.update!(acc, :archived, &(&1 + 1))

      {:error, _changeset} ->
        acc
    end
  end

  defp next_fitness(strategy, score) do
    total = max(strategy.success_count + strategy.failure_count + 1, 1)

    (strategy.fitness_score * (total - 1) + score)
    |> Kernel./(total)
    |> Float.round(4)
  end

  defp success_increment("succeeded"), do: 1
  defp success_increment(_status), do: 0

  defp failure_increment("succeeded"), do: 0
  defp failure_increment(_status), do: 1

  defp success_rate(%{usage_count: usage_count}) when usage_count <= 0, do: 0.0
  defp success_rate(strategy), do: strategy.success_count / strategy.usage_count

  defp next_status(%{status: "experimental"} = strategy, "succeeded", fitness) do
    if promote?(strategy, fitness), do: "active", else: "experimental"
  end

  defp next_status(%{status: "experimental"}, _status, _fitness) do
    "archived"
  end

  defp next_status(strategy, _status, _fitness), do: strategy.status

  defp promoted_at(%{status: "experimental"} = strategy, "succeeded", fitness) do
    if promote?(strategy, fitness), do: DateTime.utc_now(), else: strategy.promoted_at
  end

  defp promoted_at(strategy, _status, _fitness), do: strategy.promoted_at

  defp promote?(strategy, fitness) do
    strategy.usage_count >= Config.evolution_experiment_min_usage() and
      fitness >= Config.evolution_mutation_threshold()
  end

  defp maybe_record_promotion(%{status: "experimental"}, %{status: "active"} = strategy) do
    StrategyEvents.create(strategy, "promoted", "fitness_threshold_met", %{
      "fitness_score" => strategy.fitness_score
    })
  end

  defp maybe_record_promotion(_previous, _updated), do: :ok

  defp maybe_deprecate_parent(%{parent_strategy_id: nil}, _next_status, _fitness), do: :ok

  defp maybe_deprecate_parent(%{parent_strategy_id: parent_id}, "active", fitness) do
    parent = Repo.get(Strategy, parent_id)

    if parent && fitness > parent.fitness_score do
      parent
      |> Strategy.changeset(%{status: "deprecated"})
      |> Repo.update()
      |> case do
        {:ok, deprecated} ->
          StrategyEvents.create(deprecated, "deprecated", "child_promoted", %{
            "child_fitness_score" => fitness
          })

        _error ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_deprecate_parent(_strategy, _status, _fitness), do: :ok
end
