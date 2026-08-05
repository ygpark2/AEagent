defmodule AOSWeb.V1.GoalController do
  use Phoenix.Controller, formats: [:json]
  use Gettext, backend: AOSWeb.Gettext

  alias AOS.AgentOS.Goals

  action_fallback AOSWeb.FallbackController

  def index(conn, params) do
    goals =
      Goals.list_goals(
        limit: parse_limit(Map.get(params, "limit", "50")),
        status: Map.get(params, "status"),
        owner: Map.get(params, "owner")
      )
      |> Enum.map(&Goals.serialize_goal/1)

    json(conn, %{data: goals})
  end

  def create(conn, params) do
    with {:ok, goal} <- Goals.create_goal(Map.delete(params, "id")) do
      conn
      |> put_status(:created)
      |> json(%{data: Goals.serialize_goal(goal)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Goals.get_goal(id) do
      nil ->
        {:error, :not_found}

      goal ->
        json(conn, %{
          data: %{
            goal: Goals.serialize_goal(goal),
            events: Goals.list_events(goal.id) |> Enum.map(&Goals.serialize_event/1),
            runs: Goals.list_runs(goal.id) |> Enum.map(&Goals.serialize_run/1)
          }
        })
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, goal} <- Goals.update_goal(id, Map.delete(params, "id")) do
      json(conn, %{data: Goals.serialize_goal(goal)})
    end
  end

  def events(conn, %{"id" => id} = params) do
    with goal when not is_nil(goal) <- Goals.get_goal(id) do
      events =
        Goals.list_events(goal.id, limit: parse_limit(Map.get(params, "limit", "50")))
        |> Enum.map(&Goals.serialize_event/1)

      json(conn, %{data: events})
    else
      _ -> {:error, :not_found}
    end
  end

  def runs(conn, %{"id" => id} = params) do
    with goal when not is_nil(goal) <- Goals.get_goal(id) do
      runs =
        Goals.list_runs(goal.id, limit: parse_limit(Map.get(params, "limit", "50")))
        |> Enum.map(&Goals.serialize_run/1)

      json(conn, %{data: runs})
    else
      _ -> {:error, :not_found}
    end
  end

  def trigger(conn, %{"id" => id, "event_type" => event_type} = params)
      when is_binary(event_type) do
    wait? = Map.get(params, "wait", false) == true
    payload = Map.get(params, "payload", %{})

    opts = [
      source: Map.get(params, "source", "api"),
      idempotency_key: Map.get(params, "idempotency_key"),
      async: !wait?,
      execution_async: !wait?,
      start_immediately: Map.get(params, "start_immediately", true) == true,
      session_id: Map.get(params, "session_id")
    ]

    with {:ok, event} <- Goals.trigger(id, event_type, payload, opts) do
      goal = Goals.get_goal!(id)
      run = Goals.list_runs(goal.id) |> Enum.find(&(&1.event_id == event.id))

      conn
      |> put_status(:accepted)
      |> json(%{
        data: %{
          event: Goals.serialize_event(event),
          run: if(run, do: Goals.serialize_run(run), else: nil)
        }
      })
    end
  end

  def trigger(_conn, _params), do: {:error, "event_type is required"}

  def pause(conn, %{"id" => id}) do
    with {:ok, goal} <- Goals.pause_goal(id), do: json(conn, %{data: Goals.serialize_goal(goal)})
  end

  def resume(conn, %{"id" => id}) do
    with {:ok, goal} <- Goals.resume_goal(id), do: json(conn, %{data: Goals.serialize_goal(goal)})
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, goal} <- Goals.cancel_goal(id), do: json(conn, %{data: Goals.serialize_goal(goal)})
  end

  defp parse_limit(value) when is_integer(value), do: min(max(value, 1), 100)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> parse_limit(int)
      :error -> 50
    end
  end
end
