defmodule AOSWeb.V1.ExecutionController do
  use Phoenix.Controller, formats: [:json]
  use Gettext, backend: AOSWeb.Gettext

  import Plug.Conn

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Tools

  action_fallback AOSWeb.FallbackController

  def index(conn, params) do
    limit =
      params
      |> Map.get("limit", "20")
      |> parse_limit()

    executions =
      Executions.list_executions(limit: limit)
      |> Enum.map(&Executions.serialize_execution/1)

    json(conn, %{data: executions})
  end

  def show(conn, %{"id" => id}) do
    case Executions.get_execution(id) do
      nil ->
        {:error, :not_found}

      execution ->
        replay = Executions.replay_execution(execution.id)

        artifacts =
          execution.id
          |> Executions.list_artifacts()
          |> Enum.map(&Executions.serialize_artifact/1)

        delegation_traces =
          execution.id
          |> Executions.list_delegation_traces()
          |> Enum.map(&Executions.serialize_delegation_trace/1)

        tool_audits =
          execution.id
          |> Tools.list_audits()
          |> Enum.map(&Tools.serialize_audit/1)

        json(conn, %{
          data: %{
            execution: Executions.serialize_execution(execution),
            lineage: replay.lineage,
            latest_checkpoint: replay.latest_checkpoint,
            artifacts: artifacts,
            delegation_traces: delegation_traces,
            tool_audits: tool_audits
          }
        })
    end
  end

  def create(conn, %{"task" => task} = params) when is_binary(task) do
    wait? = Map.get(params, "wait", false) == true
    start_immediately? = Map.get(params, "start_immediately", true) == true
    session_id = Map.get(params, "session_id")
    autonomy_level = Map.get(params, "autonomy_level")
    engine = Map.get(params, "engine")

    with {:ok, execution} <-
           Executions.enqueue(task,
             async: !wait?,
             start_immediately: start_immediately?,
             session_id: session_id,
             autonomy_level: autonomy_level,
             engine: engine
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{data: Executions.serialize_execution(execution)})
    end
  end

  def create(_conn, _params), do: {:error, "task is required"}

  def resume(conn, %{"id" => id} = params) do
    with {:ok, execution} <-
           Executions.resume_execution(id,
             async: Map.get(params, "wait", false) != true,
             start_immediately: Map.get(params, "start_immediately", true) == true,
             checkpoint_id: Map.get(params, "checkpoint_id"),
             resume_mode: Map.get(params, "resume_mode")
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{data: Executions.serialize_execution(execution)})
    end
  end

  def retry(conn, %{"id" => id} = params) do
    with {:ok, execution} <-
           Executions.retry_execution(id,
             async: Map.get(params, "wait", false) != true,
             start_immediately: Map.get(params, "start_immediately", true) == true
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{data: Executions.serialize_execution(execution)})
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, _event} <- Executions.cancel_dag_execution(id) do
      conn
      |> put_status(:accepted)
      |> json(%{data: %{execution_id: id, status: "cancellation_requested"}})
    end
  end

  def replay(conn, %{"id" => id}) do
    json(conn, %{data: Executions.replay_execution(id)})
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp parse_limit(value) when is_integer(value), do: min(max(value, 1), 100)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> parse_limit(int)
      :error -> 20
    end
  end
end
