defmodule AOS.AgentOS.Orchestration.DAGDefinition do
  @moduledoc "Normalizes Graph structs and JSON-like DAG definitions for DAGEngine."

  alias AOS.AgentOS.Core.{Graph, NodeRegistry}

  def normalize(%Graph{} = graph), do: normalize(from_graph(graph))

  def normalize(definition) when is_map(definition) do
    with {:ok, nodes, node_options} <- normalize_nodes(fetch(definition, :nodes, %{})),
         {:ok, edges} <-
           normalize_edges(fetch(definition, :edges, fetch(definition, :transitions, []))),
         {:ok, initial_nodes} <- normalize_initial_nodes(definition, nodes, edges),
         :ok <- validate_edges(edges, nodes) do
      {:ok,
       %{
         id: fetch(definition, :id, :dag),
         domain: fetch(definition, :domain, :general),
         nodes: nodes,
         node_options: node_options,
         edges: edges,
         initial_nodes: initial_nodes,
         join_policies: fetch(definition, :join_policies, %{}),
         metadata: fetch(definition, :metadata, %{})
       }}
    end
  end

  def normalize(_definition), do: {:error, :invalid_dag_definition}

  def from_graph(%Graph{} = graph) do
    %{
      id: graph.id,
      domain: graph.domain || :general,
      nodes: graph.nodes,
      node_options: %{},
      initial_nodes: [graph.initial_node],
      join_policies: %{},
      metadata: %{},
      edges:
        Enum.flat_map(graph.transitions, fn {from, transitions} ->
          transitions
          |> Enum.reject(&is_nil(&1.to))
          |> Enum.map(fn transition ->
            %{from: from, to: transition.to, on: transition.on, condition: %{}, metadata: %{}}
          end)
        end)
    }
  end

  def successors(definition, node_id, outcome) do
    definition.edges
    |> Enum.filter(&(&1.from == node_id and outcome_matches?(&1.on, outcome)))
    |> Enum.map(& &1.to)
    |> Enum.uniq()
  end

  def predecessors(definition, node_id), do: Enum.filter(definition.edges, &(&1.to == node_id))

  def join_policy(definition, node_id) do
    policy =
      definition.join_policies
      |> fetch(node_id, fetch(definition.join_policies, to_string(node_id), "all"))

    normalize_join_policy(policy)
  end

  def serialize(definition) do
    %{
      "id" => to_string(definition.id),
      "domain" => to_string(definition.domain),
      "nodes" =>
        Map.new(definition.nodes, fn {node_id, module} ->
          {to_string(node_id), NodeRegistry.component_id_for_module(module) || inspect(module)}
        end),
      "node_options" => stringify_map(definition.node_options),
      "initial_nodes" => Enum.map(definition.initial_nodes, &to_string/1),
      "join_policies" => stringify_map(definition.join_policies),
      "edges" =>
        Enum.map(definition.edges, fn edge ->
          %{
            "from" => to_string(edge.from),
            "to" => to_string(edge.to),
            "on" => if(is_nil(edge.on), do: nil, else: to_string(edge.on)),
            "condition" => edge.condition || %{},
            "metadata" => edge.metadata || %{}
          }
        end),
      "metadata" => definition.metadata || %{}
    }
  end

  defp normalize_nodes(nodes) when is_map(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}, %{}}, fn {node_id, spec}, {:ok, modules, options} ->
      {component, node_options} = normalize_node_spec(spec)

      case resolve_node(component) do
        nil ->
          {:halt, {:error, {:unknown_dag_node, component}}}

        module ->
          {:cont,
           {:ok, Map.put(modules, normalize_id(node_id), module),
            Map.put(options, normalize_id(node_id), node_options)}}
      end
    end)
  end

  defp normalize_nodes(_nodes), do: {:error, :invalid_dag_nodes}

  defp normalize_node_spec(%{} = spec) do
    component = fetch(spec, :component, fetch(spec, :module, fetch(spec, :type)))
    {component, Map.drop(spec, [:component, "component", :module, "module", :type, "type"])}
  end

  defp normalize_node_spec(spec), do: {spec, %{}}

  defp resolve_node(module) when is_atom(module), do: module
  defp resolve_node(component) when is_binary(component), do: NodeRegistry.get_node(component)
  defp resolve_node(_component), do: nil

  defp normalize_edges(edges) when is_list(edges) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, acc} ->
      from = fetch(edge, :from)
      to = fetch(edge, :to)

      if is_nil(from) or is_nil(to) do
        {:halt, {:error, :invalid_dag_edge}}
      else
        normalized = %{
          from: normalize_id(from),
          to: normalize_id(to),
          on: normalize_outcome(fetch(edge, :on)),
          condition: fetch(edge, :condition, %{}),
          metadata: fetch(edge, :metadata, %{})
        }

        {:cont, {:ok, acc ++ [normalized]}}
      end
    end)
  end

  defp normalize_edges(_edges), do: {:error, :invalid_dag_edges}

  defp normalize_initial_nodes(definition, nodes, edges) do
    initial =
      fetch(definition, :initial_nodes, nil) ||
        case fetch(definition, :initial_node, nil) do
          nil ->
            Map.keys(nodes)
            |> Enum.filter(fn node ->
              not Enum.any?(edges, &(&1.to == node))
            end)

          value ->
            [value]
        end

    initial = if is_list(initial), do: initial, else: [initial]
    normalized = Enum.map(initial, &normalize_id/1)

    if normalized != [] and Enum.all?(normalized, &Map.has_key?(nodes, &1)),
      do: {:ok, normalized},
      else: {:error, :invalid_dag_initial_nodes}
  end

  defp validate_edges(edges, nodes) do
    if Enum.all?(edges, &(Map.has_key?(nodes, &1.from) and Map.has_key?(nodes, &1.to))),
      do: :ok,
      else: {:error, :invalid_dag_edge_node}
  end

  defp outcome_matches?(nil, _outcome), do: true

  defp outcome_matches?(expected, outcome),
    do: normalize_outcome(expected) == normalize_outcome(outcome)

  defp normalize_join_policy(%{} = policy) do
    mode = fetch(policy, :mode, "all")
    Map.put(policy, :mode, to_string(mode))
  end

  defp normalize_join_policy(mode), do: %{mode: to_string(mode || "all")}

  defp normalize_outcome(nil), do: nil
  defp normalize_outcome(value), do: value |> to_string() |> String.downcase()

  defp normalize_id(value), do: to_string(value)

  defp fetch(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, normalize_key(key), default))
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(value), do: value
end
