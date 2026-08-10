defmodule AOS.AgentOS.Evolution.StrategyMutator do
  @moduledoc """
  Applies conservative graph mutations based on the last observed failure category.
  """

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Evolution.Strategy

  @mutation_rules %{
    "bad_llm_output" => :ensure_evaluator,
    "invalid_graph" => :ensure_evaluator,
    "execution_error" => :ensure_evaluator,
    "quality_low" => :ensure_evaluator,
    "budget_exceeded" => :simplify,
    "timeout" => :simplify,
    "policy_blocked" => :simplify,
    "user_rejected" => :simplify,
    "output_limit_exceeded" => :ensure_reporter,
    "insufficient_context" => :prepend_skill_selector,
    "tool_error" => :prepend_intent_router,
    "delegation_failed" => :remove_delegator
  }

  def maybe_mutate(%Strategy{} = strategy) do
    category = get_in(strategy.metadata || %{}, ["last_failure_category"])

    if mutation_candidate?(strategy, category) do
      mutate(strategy.graph_blueprint, category)
    else
      :none
    end
  end

  def mutate(blueprint, category) when is_map(blueprint) do
    case Map.get(@mutation_rules, category) do
      nil -> :none
      rule -> {:ok, apply_rule(blueprint, rule), category}
    end
  end

  def mutate(_blueprint, _category), do: :none

  defp apply_rule(blueprint, :ensure_evaluator), do: ensure_evaluator_before_reporter(blueprint)
  defp apply_rule(blueprint, :simplify), do: simplify_to_worker_reporter(blueprint)
  defp apply_rule(blueprint, :ensure_reporter), do: ensure_reporter_terminal(blueprint)

  defp apply_rule(blueprint, :prepend_skill_selector),
    do: prepend_node(blueprint, "skill_selector", "skill_selector")

  defp apply_rule(blueprint, :prepend_intent_router),
    do: prepend_node(blueprint, "router", "router")

  defp apply_rule(blueprint, :remove_delegator), do: remove_delegator(blueprint)

  defp mutation_candidate?(strategy, category) do
    is_binary(category) and strategy.failure_count > 0 and
      strategy.fitness_score < Config.evolution_mutation_threshold()
  end

  defp ensure_evaluator_before_reporter(blueprint) do
    nodes =
      blueprint
      |> Map.get("nodes", %{})
      |> Map.put_new("critic", "critic")

    transitions =
      blueprint
      |> Map.get("transitions", [])
      |> Enum.map(fn
        %{"to" => "reporter"} = transition -> %{transition | "to" => "critic"}
        transition -> transition
      end)
      |> Enum.reject(fn
        %{"from" => "critic", "on" => "fail"} -> true
        _transition -> false
      end)
      |> append_unique(%{"from" => "critic", "on" => "pass", "to" => "reporter"})
      |> append_unique(%{
        "from" => "critic",
        "on" => "fail",
        "to" => refinement_target(blueprint, "critic")
      })

    blueprint
    |> Map.put("nodes", nodes)
    |> Map.put("transitions", transitions)
  end

  defp refinement_target(blueprint, evaluator_id) do
    nodes = Map.get(blueprint, "nodes", %{})

    Enum.find(["thinker", "worker"], &Map.has_key?(nodes, &1)) ||
      blueprint
      |> Map.get("transitions", [])
      |> Enum.find_value(fn
        %{"to" => ^evaluator_id, "from" => from} ->
          if from not in [evaluator_id, "reporter"], do: from

        _transition ->
          nil
      end) ||
      "reporter"
  end

  defp simplify_to_worker_reporter(blueprint) do
    nodes = Map.get(blueprint, "nodes", %{})

    if Map.has_key?(nodes, "thinker") and Map.has_key?(nodes, "reporter") do
      Map.merge(blueprint, %{
        "initial_node" => "thinker",
        "nodes" => %{"thinker" => "thinker", "reporter" => "reporter"},
        "transitions" => [
          %{"from" => "thinker", "on" => "success", "to" => "reporter"},
          %{"from" => "reporter", "on" => "success", "to" => nil}
        ]
      })
    else
      ensure_reporter_terminal(blueprint)
    end
  end

  defp ensure_reporter_terminal(blueprint) do
    nodes =
      blueprint
      |> Map.get("nodes", %{})
      |> Map.put_new("reporter", "reporter")

    transitions =
      blueprint
      |> Map.get("transitions", [])
      |> append_unique(%{"from" => "reporter", "on" => "success", "to" => nil})

    blueprint
    |> Map.put("nodes", nodes)
    |> Map.put("transitions", transitions)
  end

  defp prepend_node(blueprint, node_id, component_id) do
    previous_initial = Map.get(blueprint, "initial_node")

    nodes =
      blueprint
      |> Map.get("nodes", %{})
      |> Map.put_new(node_id, component_id)

    transitions =
      blueprint
      |> Map.get("transitions", [])
      |> append_unique(%{"from" => node_id, "on" => "success", "to" => previous_initial})

    blueprint
    |> Map.put("initial_node", node_id)
    |> Map.put("nodes", nodes)
    |> Map.put("transitions", transitions)
  end

  defp remove_delegator(blueprint) do
    nodes =
      blueprint
      |> Map.get("nodes", %{})
      |> Map.delete("delegator")

    transitions =
      blueprint
      |> Map.get("transitions", [])
      |> Enum.reject(&(Map.get(&1, "from") == "delegator" or Map.get(&1, "to") == "delegator"))

    blueprint
    |> Map.put("nodes", nodes)
    |> Map.put("transitions", transitions)
    |> ensure_reporter_terminal()
  end

  defp append_unique(transitions, transition) do
    if Enum.any?(transitions, &(&1 == transition)) do
      transitions
    else
      transitions ++ [transition]
    end
  end
end
