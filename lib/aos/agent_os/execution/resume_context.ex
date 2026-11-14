defmodule AOS.AgentOS.Execution.ResumeContext do
  @moduledoc """
  Typed resume context restored from checkpoints or resume seeds.
  """

  alias AOS.AgentOS.Core.NodeId

  @known_keys ~w(
    feedback result execution_result cost_usd estimated_cost
    checkpoint_artifact_id resume_mode resume_from_node
    goal_id goal_event_id goal_run_id goal_name goal_objective
    goal_success_criteria goal_constraints goal_context goal_event
    artifacts node_outputs inputs execution_history
    history llm_usage selected_skills skills custom_fields
  )a

  defstruct [
    :feedback,
    :result,
    :execution_result,
    :cost_usd,
    :estimated_cost,
    :checkpoint_artifact_id,
    :resume_mode,
    :resume_from_node,
    :goal_id,
    :goal_event_id,
    :goal_run_id,
    :goal_name,
    :goal_objective,
    :goal_success_criteria,
    :goal_constraints,
    :goal_context,
    :goal_event,
    :artifacts,
    :node_outputs,
    :inputs,
    :execution_history,
    :history,
    :llm_usage,
    :selected_skills,
    :skills,
    custom_fields: %{}
  ]

  def from_map(%__MODULE__{} = context), do: context

  def from_map(context) when is_map(context) do
    history =
      case fetch(context, "history") do
        nil -> nil
        h -> normalize_history(h)
      end

    artifacts =
      case fetch(context, "artifacts") do
        nil -> nil
        list when is_list(list) -> restore_artifacts(list)
        map when is_map(map) -> restore_artifacts(map)
        other -> other
      end

    node_outputs =
      case fetch(context, "node_outputs") do
        nil -> nil
        map when is_map(map) -> restore_node_outputs(map)
        other -> other
      end

    inputs =
      case fetch(context, "inputs") do
        nil -> nil
        map when is_map(map) -> restore_output_map(map)
        other -> other
      end

    execution_history =
      case fetch(context, "execution_history") do
        nil -> nil
        list when is_list(list) -> restore_execution_history(list)
        other -> other
      end

    custom_fields = extract_custom_fields(context)

    %__MODULE__{
      feedback: fetch(context, "feedback"),
      result: fetch(context, "result"),
      execution_result: fetch(context, "execution_result"),
      history: history,
      cost_usd: fetch(context, "cost_usd"),
      estimated_cost: fetch(context, "estimated_cost"),
      llm_usage: fetch(context, "llm_usage"),
      selected_skills: fetch(context, "selected_skills"),
      skills: fetch(context, "skills"),
      checkpoint_artifact_id: fetch(context, "checkpoint_artifact_id"),
      resume_mode: fetch(context, "resume_mode"),
      resume_from_node: normalize_node(fetch(context, "resume_from_node")),
      goal_id: fetch(context, "goal_id"),
      goal_event_id: fetch(context, "goal_event_id"),
      goal_run_id: fetch(context, "goal_run_id"),
      goal_name: fetch(context, "goal_name"),
      goal_objective: fetch(context, "goal_objective"),
      goal_success_criteria: fetch(context, "goal_success_criteria"),
      goal_constraints: fetch(context, "goal_constraints"),
      goal_context: fetch(context, "goal_context"),
      goal_event: fetch(context, "goal_event"),
      artifacts: artifacts,
      node_outputs: node_outputs,
      inputs: inputs,
      execution_history: execution_history,
      custom_fields: custom_fields
    }
  end

  def from_map(_context), do: %__MODULE__{}

  def to_map(%__MODULE__{} = context) do
    base =
      %{
        feedback: context.feedback,
        result: context.result,
        execution_result: context.execution_result,
        history: context.history,
        cost_usd: context.cost_usd,
        estimated_cost: context.estimated_cost,
        llm_usage: context.llm_usage,
        selected_skills: context.selected_skills,
        skills: context.skills,
        checkpoint_artifact_id: context.checkpoint_artifact_id,
        resume_mode: context.resume_mode,
        resume_from_node: context.resume_from_node,
        goal_id: context.goal_id,
        goal_event_id: context.goal_event_id,
        goal_run_id: context.goal_run_id,
        goal_name: context.goal_name,
        goal_objective: context.goal_objective,
        goal_success_criteria: context.goal_success_criteria,
        goal_constraints: context.goal_constraints,
        goal_context: context.goal_context,
        goal_event: context.goal_event,
        artifacts: context.artifacts,
        node_outputs: context.node_outputs,
        inputs: context.inputs,
        execution_history: context.execution_history
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with_fallback =
      base
      |> maybe_put_fallback(:artifacts, "artifacts", context.artifacts)
      |> maybe_put_fallback(:node_outputs, "node_outputs", context.node_outputs)
      |> maybe_put_fallback(:inputs, "inputs", context.inputs)
      |> maybe_put_fallback(:execution_history, "execution_history", context.execution_history)

    custom = context.custom_fields || %{}
    Map.merge(custom, with_fallback)
  end

  def to_map(context) when is_map(context) do
    context
    |> from_map()
    |> to_map()
  end

  defp maybe_put_fallback(map, _atom_key, str_key, val) when not is_nil(val),
    do: Map.put(map, str_key, val)

  defp maybe_put_fallback(map, _atom_key, _str_key, _val), do: map

  defp fetch(context, key, default \\ nil)

  defp fetch(context, key, default) when is_map(context) do
    atom_val = Map.get(context, normalize_key(key))
    str_val = Map.get(context, to_string(key))
    resolve_fetch_value(atom_val, str_val, default)
  end

  defp fetch(_context, _key, default), do: default

  defp resolve_fetch_value(atom_val, str_val, _default)
       when is_map(atom_val) and is_map(str_val) and atom_val != str_val do
    Map.merge(str_val, atom_val)
  end

  defp resolve_fetch_value(atom_val, str_val, _default)
       when is_list(atom_val) and is_list(str_val) and atom_val != str_val do
    Enum.uniq(atom_val ++ str_val)
  end

  defp resolve_fetch_value(atom_val, _str_val, _default) when not is_nil(atom_val), do: atom_val
  defp resolve_fetch_value(_atom_val, str_val, _default) when not is_nil(str_val), do: str_val
  defp resolve_fetch_value(_atom_val, _str_val, default), do: default

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp extract_custom_fields(context) when is_map(context) do
    base_custom =
      case fetch(context, "custom_fields") do
        map when is_map(map) -> map
        _ -> %{}
      end

    known_string_keys = Enum.map(@known_keys, &to_string/1)

    Enum.reduce(context, base_custom, fn {key, value}, acc ->
      str_key = to_string(key)

      if str_key in known_string_keys do
        acc
      else
        atom_key = atomize_key(key)
        restored_val = restore_custom_value(value)

        acc
        |> Map.put(key, restored_val)
        |> Map.put(atom_key, restored_val)
      end
    end)
  end

  defp restore_custom_value(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      atom_k = atomize_key(k)
      acc |> Map.put(k, v) |> Map.put(atom_k, v)
    end)
  end

  defp restore_custom_value(other), do: other

  defp restore_artifacts(artifacts) when is_list(artifacts) do
    Enum.map(artifacts, &restore_artifact/1)
  end

  defp restore_artifacts(artifact) when is_map(artifact) do
    restore_artifact(artifact)
  end

  defp restore_artifacts(other), do: other

  defp restore_artifact(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      atom_k = atomize_key(k)

      restored_v =
        if is_map(v) and not is_struct(v) and k in ["payload", :payload, "metadata", :metadata] do
          restore_artifact(v)
        else
          v
        end

      acc
      |> Map.put(k, restored_v)
      |> Map.put(atom_k, restored_v)
    end)
  end

  defp restore_artifact(other), do: other

  defp restore_node_outputs(node_outputs) when is_map(node_outputs) do
    Enum.reduce(node_outputs, %{}, fn {node_id, output}, acc ->
      restored_output = restore_output_map(output)
      atom_id = atomize_key(node_id)

      acc
      |> Map.put(to_string(node_id), restored_output)
      |> Map.put(atom_id, restored_output)
    end)
  end

  defp restore_node_outputs(other), do: other

  defp restore_output_map(output) when is_map(output) and not is_struct(output) do
    Enum.reduce(output, %{}, fn {k, v}, acc ->
      atom_k = atomize_key(k)

      restored_v =
        if atom_k == :artifacts or k == "artifacts",
          do: restore_artifacts(v),
          else: v

      acc
      |> Map.put(k, restored_v)
      |> Map.put(atom_k, restored_v)
    end)
  end

  defp restore_output_map(other), do: other

  defp restore_execution_history(history) when is_list(history) do
    Enum.map(history, fn
      %{} = step ->
        node_id = Map.get(step, :node_id, Map.get(step, "node_id"))
        outcome = Map.get(step, :outcome, Map.get(step, "outcome"))
        feedback = Map.get(step, :feedback, Map.get(step, "feedback"))
        timestamp = Map.get(step, :timestamp, Map.get(step, "timestamp"))

        %{
          :node_id => node_id,
          "node_id" => node_id,
          :outcome => outcome,
          "outcome" => outcome,
          :feedback => feedback,
          "feedback" => feedback,
          :timestamp => timestamp,
          "timestamp" => timestamp
        }

      other ->
        other
    end)
  end

  defp restore_execution_history(other), do: other

  defp atomize_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp atomize_key(k), do: k

  defp normalize_history(history) when is_list(history) do
    Enum.map(history, fn
      {role, content} -> {to_string(role), content}
      %{"role" => role, "content" => content} -> {to_string(role), content}
      %{role: role, content: content} -> {to_string(role), content}
      other -> {"system", inspect(other)}
    end)
  end

  defp normalize_history(_history), do: []

  defp normalize_node(nil), do: nil
  defp normalize_node(value) when is_atom(value), do: value
  defp normalize_node(value) when is_binary(value), do: NodeId.normalize(value)
end
