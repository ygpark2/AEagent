defmodule AOS.AgentOS.Harness.Store do
  @moduledoc "Persistence boundary for harness episodes and trace events."

  import Ecto.Query

  alias AOS.AgentOS.Core.{HarnessEpisode, HarnessTrace}
  alias AOS.Repo

  def get_episode(id), do: Repo.get(HarnessEpisode, id)

  def get_episode_by_execution(execution_id),
    do: Repo.get_by(HarnessEpisode, execution_id: execution_id)

  def create_episode(attrs) do
    %HarnessEpisode{}
    |> HarnessEpisode.changeset(attrs)
    |> Repo.insert()
  end

  def update_episode(%HarnessEpisode{} = episode, attrs) do
    episode
    |> HarnessEpisode.changeset(attrs)
    |> Repo.update()
  end

  def update_episode(id, attrs), do: id |> Repo.get!(HarnessEpisode) |> update_episode(attrs)

  def append_trace(attrs) do
    episode_id = Map.get(attrs, :episode_id)
    key = Map.get(attrs, :idempotency_key)

    if key do
      case Repo.get_by(HarnessTrace, episode_id: episode_id, idempotency_key: key) do
        nil -> insert_trace(attrs)
        trace -> {:ok, trace}
      end
    else
      insert_trace(attrs)
    end
  end

  def list_traces(episode_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1_000)

    HarnessTrace
    |> where([trace], trace.episode_id == ^episode_id)
    |> order_by([trace], asc: trace.sequence, asc: trace.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def serialize_episode(%HarnessEpisode{} = episode) do
    %{
      id: episode.id,
      execution_id: episode.execution_id,
      dag_run_id: episode.dag_run_id,
      status: episode.status,
      manifest: episode.manifest,
      budget: episode.budget,
      verification: episode.verification,
      failure_attribution: episode.failure_attribution,
      summary: episode.summary,
      intervention_count: episode.intervention_count,
      started_at: episode.started_at,
      finished_at: episode.finished_at,
      inserted_at: episode.inserted_at,
      updated_at: episode.updated_at
    }
  end

  def serialize_trace(%HarnessTrace{} = trace) do
    %{
      id: trace.id,
      episode_id: trace.episode_id,
      execution_id: trace.execution_id,
      trace_type: trace.trace_type,
      phase: trace.phase,
      payload: trace.payload,
      sequence: trace.sequence,
      source: trace.source,
      idempotency_key: trace.idempotency_key,
      inserted_at: trace.inserted_at
    }
  end

  defp insert_trace(attrs) do
    attrs = Map.put_new(attrs, :sequence, next_sequence(Map.get(attrs, :episode_id)))

    %HarnessTrace{}
    |> HarnessTrace.changeset(attrs)
    |> Repo.insert()
  end

  defp next_sequence(nil), do: 0

  defp next_sequence(episode_id) do
    HarnessTrace
    |> where([trace], trace.episode_id == ^episode_id)
    |> select([trace], max(trace.sequence))
    |> Repo.one()
    |> case do
      nil -> 0
      sequence -> sequence + 1
    end
  end
end
