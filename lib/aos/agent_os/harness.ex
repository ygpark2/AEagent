defmodule AOS.AgentOS.Harness do
  @moduledoc "Public facade for the explicit agent harness runtime."

  alias AOS.AgentOS.Harness.{EntropyAuditor, Episode, Manifest, Store, VerificationGate}

  def ensure_episode(execution, context, opts \\ []), do: Episode.ensure(execution, context, opts)
  def manifest(context, opts \\ []), do: Manifest.for_context(context, opts)
  def verify(context, opts \\ []), do: VerificationGate.verify(context, opts)
  def mark_running(execution_id), do: Episode.mark_running(execution_id)

  def finish(execution_id, status, context, reason \\ nil),
    do: Episode.finish(execution_id, status, context, reason)

  def trace(execution_id, trace_type, phase, payload, opts \\ []),
    do: Episode.trace(execution_id, trace_type, phase, payload, opts)

  def record_failure(execution_id, reason, context),
    do: Episode.record_failure(execution_id, reason, context)

  def record_intervention(execution_id, attrs),
    do: Episode.record_intervention(execution_id, attrs)

  def manifest_for_execution(execution_id), do: Episode.manifest_for_execution(execution_id)

  def attach_dag_run(execution_id, dag_run_id),
    do: Episode.attach_dag_run(execution_id, dag_run_id)

  def audit_entropy(root \\ nil, opts \\ [])
  def audit_entropy(root, opts) when is_list(opts), do: EntropyAuditor.audit(root, opts)

  def audit_entropy(root, manifest) when is_map(manifest),
    do: EntropyAuditor.audit_manifest(root, manifest)

  def get_episode(execution_id), do: Store.get_episode_by_execution(execution_id)
  def list_traces(episode_id, opts \\ []), do: Store.list_traces(episode_id, opts)
  def serialize_episode(episode), do: Store.serialize_episode(episode)
  def serialize_trace(trace), do: Store.serialize_trace(trace)
end
