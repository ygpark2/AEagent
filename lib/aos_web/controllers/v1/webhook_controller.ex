defmodule AOSWeb.V1.WebhookController do
  use Phoenix.Controller, formats: [:json]
  use Gettext, backend: AOSWeb.Gettext

  import Plug.Conn

  alias AOS.AgentOS.Channels.SecurityConfig
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Goals

  action_fallback AOSWeb.FallbackController

  def create(conn, %{"task" => task} = params) when is_binary(task) do
    with :ok <- authorize_webhook(conn),
         {:ok, execution} <-
           Executions.enqueue(task,
             async: Map.get(params, "wait", false) != true,
             start_immediately: Map.get(params, "start_immediately", true) == true,
             autonomy_level: Map.get(params, "autonomy_level"),
             session_id: Map.get(params, "session_id")
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{
        data: %{
          channel: "webhook",
          execution: Executions.serialize_execution(execution)
        }
      })
    end
  end

  def create(conn, _params) do
    with :ok <- authorize_webhook(conn) do
      {:error, "task is required"}
    end
  end

  def goal_event(conn, %{"id" => goal_id, "event_type" => event_type} = params)
      when is_binary(event_type) do
    wait? = Map.get(params, "wait", false) == true

    with :ok <- authorize_webhook(conn),
         {:ok, event} <-
           Goals.trigger(
             goal_id,
             event_type,
             Map.get(params, "payload", %{}),
             source: Map.get(params, "source", "webhook"),
             idempotency_key: Map.get(params, "idempotency_key"),
             async: !wait?,
             execution_async: !wait?,
             start_immediately: Map.get(params, "start_immediately", true) == true
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{data: %{channel: "goal_webhook", event: Goals.serialize_event(event)}})
    end
  end

  def goal_event(conn, _params) do
    with :ok <- authorize_webhook(conn) do
      {:error, "id and event_type are required"}
    end
  end

  defp authorize_webhook(conn) do
    configured = SecurityConfig.webhook_shared_secret()
    provided = get_req_header(conn, "x-aos-webhook-secret") |> List.first()

    if valid_secret?(provided, configured) do
      :ok
    else
      {:error, "invalid webhook secret"}
    end
  end

  defp valid_secret?(provided, configured)
       when is_binary(provided) and is_binary(configured) and byte_size(configured) > 0 do
    byte_size(provided) == byte_size(configured) and
      Plug.Crypto.secure_compare(provided, configured)
  end

  defp valid_secret?(_provided, _configured), do: false
end
