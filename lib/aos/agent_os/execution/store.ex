defmodule AOS.AgentOS.Execution.Store do
  @moduledoc """
  Database access layer for executions, sessions, artifacts, and delegation traces.
  """

  import Ecto.Query

  alias AOS.AgentOS.Autonomy
  alias AOS.AgentOS.Core.{Artifact, DelegationTrace, Execution, MemoryStore, Session}
  alias AOS.AgentOS.Execution.{EventStore, StateMachine}
  alias AOS.Repo

  @default_limit 20

  def get_execution(id), do: Repo.get(Execution, id)
  def get_execution!(id), do: Repo.get!(Execution, id)

  def get_session(id), do: Repo.get(Session, id)
  def get_session!(id), do: Repo.get!(Session, id)

  def list_executions(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    session_id = Keyword.get(opts, :session_id)

    Execution
    |> maybe_filter_by_session(session_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Session
    |> order_by([s], desc: s.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_execution(attrs) do
    base_attrs = %{
      domain: "general",
      task: "unknown",
      status: "queued",
      trigger_kind: "manual",
      engine: "graph",
      autonomy_level: Autonomy.default_level(),
      success: false,
      execution_log: %{steps: []}
    }

    %Execution{}
    |> Execution.changeset(Map.merge(base_attrs, attrs))
    |> Repo.insert()
  end

  def update_execution(id, attrs) do
    execution = get_execution!(id)

    with :ok <- validate_status_transition(execution, attrs) do
      result =
        execution
        |> Execution.changeset(attrs)
        |> Repo.update()

      maybe_update_embedding(result)
    end
  end

  defp maybe_update_embedding({:ok, %Execution{success: true, embedding: nil} = updated}) do
    # Generate embedding in background to not block the main flow.
    Task.start(fn -> MemoryStore.update_embedding(updated) end)
    {:ok, updated}
  end

  defp maybe_update_embedding(result), do: result

  defp validate_status_transition(execution, %{status: next}),
    do: StateMachine.transition(execution.status, next)

  defp validate_status_transition(execution, %{"status" => next}),
    do: StateMachine.transition(execution.status, next)

  defp validate_status_transition(_execution, _attrs), do: :ok

  def create_session(task, title, autonomy_level) do
    session_title =
      title ||
        task
        |> String.trim()
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 80)

    %Session{}
    |> Session.changeset(%{
      title: session_title,
      task: task,
      status: "active",
      autonomy_level: autonomy_level,
      metadata: %{}
    })
    |> Repo.insert()
  end

  def update_session(session_id, attrs) do
    session_id
    |> get_session!()
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def update_session_metadata(session_id, attrs) when is_map(attrs) do
    session = get_session!(session_id)
    merged = Map.merge(session.metadata || %{}, attrs)
    update_session(session_id, %{metadata: merged})
  end

  def update_session_status(nil, _status, _execution_id), do: :ok

  def update_session_status(session_id, status, execution_id) do
    update_session(session_id, %{status: status, last_execution_id: execution_id})
  end

  def list_artifacts(execution_id) do
    Artifact
    |> where([a], a.execution_id == ^execution_id)
    |> order_by([a], asc: a.position, asc: a.inserted_at)
    |> Repo.all()
  end

  def get_artifact(id), do: Repo.get(Artifact, id)

  def list_delegation_traces(nil), do: []

  def list_delegation_traces(parent_execution_id) do
    DelegationTrace
    |> where([t], t.parent_execution_id == ^parent_execution_id)
    |> order_by([t], asc: t.position, asc: t.inserted_at)
    |> Repo.all()
  end

  def create_delegation_trace(attrs) do
    %DelegationTrace{}
    |> DelegationTrace.changeset(attrs)
    |> Repo.insert()
  end

  def update_delegation_trace(id, attrs) do
    DelegationTrace
    |> Repo.get!(id)
    |> DelegationTrace.changeset(attrs)
    |> Repo.update()
  end

  def append_event(attrs), do: EventStore.append_event(attrs)
  def list_events(execution_id), do: EventStore.list_events(execution_id)
  def serialize_event(event), do: EventStore.serialize(event)

  defp maybe_filter_by_session(query, nil), do: query

  defp maybe_filter_by_session(query, session_id),
    do: where(query, [e], e.session_id == ^session_id)
end
