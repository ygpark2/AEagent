defmodule AOS.AgentOS.Execution.Replay do
  @moduledoc """
  Builds replay and serialization payloads for executions and sessions.
  """

  alias AOS.AgentOS.Core.{Artifact, DelegationTrace, Execution, Session}
  alias AOS.AgentOS.Evolution.StrategyRegistry
  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.{Executions, Tools}

  def replay_execution(execution_id) do
    execution = Executions.get_execution!(execution_id)

    %{
      execution: serialize_execution(execution),
      session:
        execution.session_id
        |> Executions.get_session()
        |> maybe_serialize_session(),
      lineage: execution.id |> execution_lineage() |> Enum.map(&serialize_execution/1),
      strategy: strategy_snapshot(execution.strategy_id),
      strategy_lineage: strategy_lineage(execution.strategy_id),
      latest_checkpoint: latest_checkpoint_snapshot(execution.id),
      artifacts:
        execution.id
        |> Executions.list_artifacts()
        |> Enum.map(&serialize_artifact/1),
      delegation_traces:
        execution.id
        |> Executions.list_delegation_traces()
        |> Enum.map(&serialize_delegation_trace/1),
      tool_audits:
        execution.id
        |> Tools.list_audits()
        |> Enum.map(&Tools.serialize_audit/1),
      harness_episode:
        execution.id
        |> Executions.get_harness_episode()
        |> maybe_serialize_harness_episode(),
      harness_traces:
        execution.id
        |> Executions.list_harness_traces()
        |> Enum.map(&Executions.serialize_harness_trace/1),
      events:
        execution.id
        |> Executions.list_events()
        |> Enum.map(&EventStore.serialize/1)
    }
  end

  def serialize_execution(%Execution{} = execution) do
    %{
      id: execution.id,
      session_id: execution.session_id,
      goal_id: execution.goal_id,
      workflow_id: execution.workflow_id,
      engine: execution.engine,
      domain: execution.domain,
      task: execution.task,
      status: execution.status,
      source_execution_id: execution.source_execution_id,
      trigger_kind: execution.trigger_kind,
      autonomy_level: execution.autonomy_level,
      strategy_id: execution.strategy_id,
      fitness_score: execution.fitness_score,
      quality_score: execution.quality_score,
      failure_category: execution.failure_category,
      success: execution.success,
      final_result: execution.final_result,
      error_message: execution.error_message,
      execution_log: execution.execution_log,
      latest_checkpoint: latest_checkpoint_snapshot(execution.id),
      started_at: execution.started_at,
      finished_at: execution.finished_at,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }
  end

  defp maybe_serialize_harness_episode(nil), do: nil

  defp maybe_serialize_harness_episode(episode),
    do: AOS.AgentOS.Harness.serialize_episode(episode)

  defp strategy_snapshot(nil), do: nil

  defp strategy_snapshot(strategy_id) do
    case StrategyRegistry.get_strategy(strategy_id) do
      nil -> nil
      strategy -> StrategyRegistry.serialize(strategy)
    end
  end

  defp strategy_lineage(nil), do: []

  defp strategy_lineage(strategy_id) do
    strategy_id
    |> unfold_strategy_lineage([])
    |> Enum.reverse()
  end

  defp unfold_strategy_lineage(nil, acc), do: acc

  defp unfold_strategy_lineage(strategy_id, acc) do
    case StrategyRegistry.get_strategy(strategy_id) do
      nil ->
        acc

      strategy ->
        unfold_strategy_lineage(strategy.parent_strategy_id, [
          StrategyRegistry.serialize(strategy) | acc
        ])
    end
  end

  def serialize_session(%Session{} = session) do
    %{
      id: session.id,
      title: session.title,
      task: session.task,
      status: session.status,
      autonomy_level: session.autonomy_level,
      metadata: session.metadata,
      last_execution_id: session.last_execution_id,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  def serialize_artifact(%Artifact{} = artifact) do
    %{
      id: artifact.id,
      execution_id: artifact.execution_id,
      session_id: artifact.session_id,
      kind: artifact.kind,
      label: artifact.label,
      payload: artifact.payload,
      position: artifact.position,
      inserted_at: artifact.inserted_at
    }
  end

  def serialize_delegation_trace(%DelegationTrace{} = trace) do
    %{
      id: trace.id,
      session_id: trace.session_id,
      parent_execution_id: trace.parent_execution_id,
      child_execution_id: trace.child_execution_id,
      task: trace.task,
      status: trace.status,
      position: trace.position,
      result_summary: trace.result_summary,
      error_message: trace.error_message,
      inserted_at: trace.inserted_at,
      updated_at: trace.updated_at
    }
  end

  def latest_checkpoint_snapshot(execution_id) do
    execution_id
    |> Executions.list_artifacts()
    |> Enum.reverse()
    |> Enum.find(&(&1.kind == "checkpoint"))
    |> checkpoint_snapshot()
  end

  defp checkpoint_snapshot(nil), do: nil

  defp checkpoint_snapshot(%Artifact{} = artifact) do
    payload = artifact.payload || %{}
    context = get_payload(payload, "context", %{})

    %{
      artifact_id: artifact.id,
      label: artifact.label,
      node_id: get_payload(payload, "node_id"),
      next_node_id: get_payload(payload, "next_node_id"),
      result: get_payload(context, "result"),
      feedback: get_payload(context, "feedback"),
      cost_usd: get_payload(context, "cost_usd"),
      inserted_at: artifact.inserted_at
    }
  end

  defp get_payload(payload, key, default \\ nil),
    do: Map.get(payload, key, Map.get(payload, payload_atom(key), default))

  defp payload_atom("context"), do: :context
  defp payload_atom("node_id"), do: :node_id
  defp payload_atom("next_node_id"), do: :next_node_id
  defp payload_atom("result"), do: :result
  defp payload_atom("feedback"), do: :feedback
  defp payload_atom("cost_usd"), do: :cost_usd
  defp payload_atom(key), do: key

  defp maybe_serialize_session(nil), do: nil
  defp maybe_serialize_session(session), do: serialize_session(session)

  defp execution_lineage(execution_id) do
    execution_id
    |> Executions.get_execution!()
    |> Stream.unfold(fn
      nil ->
        nil

      %Execution{} = execution ->
        parent =
          case execution.source_execution_id do
            nil -> nil
            parent_id -> Executions.get_execution(parent_id)
          end

        {execution, parent}
    end)
    |> Enum.to_list()
    |> Enum.reverse()
  end
end
