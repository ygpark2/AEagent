defmodule AOSWeb.V1.ApprovalController do
  use Phoenix.Controller, formats: [:json]
  use Gettext, backend: AOSWeb.Gettext

  import Plug.Conn

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.{ApprovalQueue, ApprovalRequest}

  action_fallback AOSWeb.FallbackController

  def index(conn, params) do
    requests =
      ApprovalQueue.list_requests(
        status: Map.get(params, "status", "pending"),
        limit: parse_limit(Map.get(params, "limit", "50"))
      )
      |> Enum.map(&ApprovalQueue.serialize/1)

    json(conn, %{data: requests})
  end

  def show(conn, %{"id" => id}) do
    case ApprovalQueue.get_request(id) do
      nil -> {:error, :not_found}
      request -> json(conn, %{data: ApprovalQueue.serialize(request)})
    end
  end

  def approve(conn, %{"id" => id} = params) do
    attrs = decision_attrs(params)

    with {:ok, request} <- ApprovalQueue.approve(id, attrs),
         {:ok, resumed_execution} <- maybe_resume(request, params) do
      conn
      |> put_status(:accepted)
      |> json(%{
        data: %{
          approval_request: ApprovalQueue.serialize(request),
          resumed_execution: maybe_serialize_execution(resumed_execution)
        }
      })
    end
  end

  def reject(conn, %{"id" => id} = params) do
    with {:ok, request} <- ApprovalQueue.reject(id, decision_attrs(params)) do
      conn
      |> put_status(:accepted)
      |> json(%{data: %{approval_request: ApprovalQueue.serialize(request)}})
    end
  end

  defp maybe_resume(%ApprovalRequest{execution_id: nil}, _params), do: {:ok, nil}

  defp maybe_resume(%ApprovalRequest{} = request, params) do
    if resume?(params) do
      Executions.resume_execution(request.execution_id,
        async: Map.get(params, "wait", false) != true,
        start_immediately: Map.get(params, "start_immediately", true) == true,
        checkpoint_id: Map.get(params, "checkpoint_id"),
        resume_mode: Map.get(params, "resume_mode")
      )
    else
      {:ok, nil}
    end
  end

  defp maybe_serialize_execution(nil), do: nil
  defp maybe_serialize_execution(execution), do: Executions.serialize_execution(execution)

  defp decision_attrs(params) do
    %{
      decided_by: Map.get(params, "decided_by"),
      decision_reason: Map.get(params, "decision_reason")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp resume?(params), do: Map.get(params, "resume", true) == true

  defp parse_limit(value) when is_integer(value), do: min(max(value, 1), 100)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> parse_limit(int)
      :error -> 50
    end
  end
end
