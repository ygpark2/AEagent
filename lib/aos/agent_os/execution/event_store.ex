defmodule AOS.AgentOS.Execution.EventStore do
  @moduledoc """
  Append-only timeline persistence for workflow execution traceability.
  """

  import Ecto.Query

  alias AOS.AgentOS.Execution.Event
  alias AOS.Repo

  def append_event(attrs) do
    attrs = Map.put_new(attrs, :position, next_position(Map.get(attrs, :execution_id)))

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  rescue
    # The SQLite adapter can't map its FK violation message to a named
    # constraint, so it raises instead of returning an error changeset.
    # Timeline events are best-effort observability, never load-bearing,
    # so a dangling execution/session/workflow id should not crash the caller.
    e in Ecto.ConstraintError -> {:error, e}
  end

  def list_events(execution_id) do
    Event
    |> where([e], e.execution_id == ^execution_id)
    |> order_by([e], asc: e.position, asc: e.inserted_at)
    |> Repo.all()
  end

  def serialize(%Event{} = event) do
    %{
      id: event.id,
      execution_id: event.execution_id,
      session_id: event.session_id,
      workflow_id: event.workflow_id,
      event_type: event.event_type,
      source: event.source,
      payload: event.payload,
      position: event.position,
      inserted_at: event.inserted_at
    }
  end

  defp next_position(nil), do: 0

  defp next_position(execution_id) do
    Event
    |> where([e], e.execution_id == ^execution_id)
    |> select([e], max(e.position))
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end
end
