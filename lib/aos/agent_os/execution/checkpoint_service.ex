defmodule AOS.AgentOS.Execution.CheckpointService do
  @moduledoc """
  Restores and serializes checkpoint context for resumed executions.
  """

  alias AOS.AgentOS.Core.Artifact
  alias AOS.AgentOS.Execution.{CheckpointSnapshot, CheckpointStore, ResumeContext}
  alias AOS.AgentOS.Executions

  @default_resume_mode "next_node"
  @resume_modes [@default_resume_mode, "checkpoint_node"]

  def normalize_resume_mode(nil), do: @default_resume_mode

  def normalize_resume_mode(mode) when mode in @resume_modes, do: mode

  def normalize_resume_mode(mode) when is_atom(mode),
    do: mode |> to_string() |> normalize_resume_mode()

  def normalize_resume_mode(_mode), do: @default_resume_mode

  def checkpoint_context(execution_id, checkpoint_id \\ nil, resume_mode \\ nil) do
    execution_id
    |> checkpoint_resume_context(checkpoint_id, resume_mode)
    |> ResumeContext.to_map()
  end

  def checkpoint_resume_context(execution_id, checkpoint_id \\ nil, resume_mode \\ nil) do
    resume_mode = normalize_resume_mode(resume_mode)

    case resolve_checkpoint(execution_id, checkpoint_id) do
      nil ->
        %ResumeContext{}

      artifact ->
        build_resume_context(artifact, resume_mode)
    end
  end

  def to_runtime_map(%ResumeContext{} = context), do: ResumeContext.to_map(context)

  def to_runtime_map(context) when is_map(context) do
    context
    |> ResumeContext.from_map()
    |> ResumeContext.to_map()
  end

  def to_runtime_map(other), do: other

  def initial_context_for_run(nil, initial_context) do
    deserialize_resume_context(initial_context)
  end

  def initial_context_for_run(execution_id, initial_context) do
    case Executions.get_execution(execution_id) do
      nil ->
        deserialize_resume_context(initial_context)

      execution ->
        base_context =
          cond do
            resume_seed = CheckpointStore.latest_resume_seed(execution.id) ->
              resume_seed
              |> Map.get(:payload, %{})
              |> payload_map("context")
              |> deserialize_resume_context()
              |> merge_initial_context(initial_context)

            execution.trigger_kind == "resume" and execution.source_execution_id ->
              execution.source_execution_id
              |> checkpoint_resume_context(nil, @default_resume_mode)
              |> merge_initial_context(initial_context)

            true ->
              deserialize_resume_context(initial_context)
          end

        ensure_resume_target(base_context, execution)
    end
  end

  def serialize_step(step) do
    %{
      node_id: Map.get(step, :node_id) || Map.get(step, "node_id") |> to_string(),
      outcome: Map.get(step, :outcome) || Map.get(step, "outcome") |> to_string(),
      feedback: Map.get(step, :feedback) || Map.get(step, "feedback"),
      timestamp: Map.get(step, :timestamp) || Map.get(step, "timestamp")
    }
  end

  defp resolve_checkpoint(_execution_id, checkpoint_id) when is_binary(checkpoint_id) do
    CheckpointStore.get_artifact(checkpoint_id)
  end

  defp resolve_checkpoint(execution_id, _checkpoint_id) do
    CheckpointStore.latest_checkpoint(execution_id)
  end

  defp payload_map(payload, key) do
    Map.get(payload, key) || Map.get(payload, known_payload_key(key)) || %{}
  end

  defp known_payload_key("context"), do: :context
  defp known_payload_key("node_id"), do: :node_id
  defp known_payload_key("next_node_id"), do: :next_node_id
  defp known_payload_key(key), do: key

  defp deserialize_resume_context(context) when is_map(context) do
    ResumeContext.from_map(context)
  end

  defp deserialize_resume_context(_context), do: %ResumeContext{}

  defp ensure_resume_target(%ResumeContext{resume_from_node: value} = context, _execution)
       when not is_nil(value),
       do: context

  defp ensure_resume_target(context, %{
         trigger_kind: "resume",
         source_execution_id: source_execution_id
       })
       when not is_nil(source_execution_id) do
    checkpoint_id = context.checkpoint_artifact_id
    resume_mode = context.resume_mode || @default_resume_mode

    source_execution_id
    |> checkpoint_resume_context(checkpoint_id, resume_mode)
    |> merge_resume_context(context)
  end

  defp ensure_resume_target(context, _execution), do: context

  defp build_resume_context(%Artifact{} = artifact, resume_mode) do
    snapshot = CheckpointSnapshot.from_artifact(artifact)

    resume_from_node =
      case resume_mode do
        "checkpoint_node" -> snapshot.node_id
        _ -> snapshot.next_node_id || snapshot.node_id
      end

    snapshot.context
    |> Map.put("checkpoint_artifact_id", snapshot.artifact_id)
    |> Map.put("resume_mode", resume_mode)
    |> Map.put("resume_from_node", resume_from_node)
    |> ResumeContext.from_map()
  end

  defp merge_initial_context(%ResumeContext{} = context, initial_context) do
    initial_map =
      case initial_context do
        %ResumeContext{} -> ResumeContext.to_map(initial_context)
        m when is_map(m) -> m
        _ -> %{}
      end

    context
    |> ResumeContext.to_map()
    |> merge_context_maps(initial_map)
    |> ResumeContext.from_map()
  end

  defp merge_resume_context(%ResumeContext{} = source, %ResumeContext{} = target) do
    source
    |> ResumeContext.to_map()
    |> merge_context_maps(ResumeContext.to_map(target))
    |> ResumeContext.from_map()
  end

  defp merge_context_maps(ctx1, ctx2) when is_map(ctx1) and is_map(ctx2) do
    merged =
      Map.merge(ctx1, ctx2, fn
        key, v1, v2 when key in [:artifacts, "artifacts"] ->
          (List.wrap(v1) ++ List.wrap(v2)) |> Enum.uniq()

        key, v1, v2 when key in [:node_outputs, "node_outputs"] and is_map(v1) and is_map(v2) ->
          Map.merge(v1, v2)

        key, v1, v2
        when key in [:execution_history, "execution_history", :history, "history"] and is_list(v1) and
               is_list(v2) ->
          v1 ++ v2

        _key, v1, v2 when is_list(v1) and is_list(v2) ->
          Enum.uniq(v1 ++ v2)

        _key, v1, v2 when is_map(v1) and is_map(v2) and not is_struct(v1) and not is_struct(v2) ->
          merge_context_maps(v1, v2)

        _key, _v1, v2 ->
          v2
      end)

    sync_schema_keys(merged)
  end

  defp merge_context_maps(ctx1, _ctx2) when is_map(ctx1), do: ctx1
  defp merge_context_maps(_ctx1, ctx2) when is_map(ctx2), do: ctx2
  defp merge_context_maps(ctx1, _ctx2), do: ctx1

  defp sync_schema_keys(map) when is_map(map) do
    Enum.reduce([:artifacts, :node_outputs, :inputs, :execution_history, :history], map, fn key,
                                                                                            acc ->
      atom_val = Map.get(acc, key)
      str_val = Map.get(acc, to_string(key))

      merged_val =
        cond do
          is_map(atom_val) and is_map(str_val) -> Map.merge(str_val, atom_val)
          is_list(atom_val) and is_list(str_val) -> Enum.uniq(str_val ++ atom_val)
          not is_nil(atom_val) -> atom_val
          not is_nil(str_val) -> str_val
          true -> nil
        end

      if is_nil(merged_val) do
        acc
      else
        acc
        |> Map.put(key, merged_val)
        |> Map.put(to_string(key), merged_val)
      end
    end)
  end
end
