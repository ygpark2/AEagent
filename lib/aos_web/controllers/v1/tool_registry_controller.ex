defmodule AOSWeb.V1.ToolRegistryController do
  use Phoenix.Controller, formats: [:json]
  use Gettext, backend: AOSWeb.Gettext

  import Plug.Conn

  alias AOS.AgentOS.MCP.Manager
  alias AOS.AgentOS.Tools

  action_fallback AOSWeb.FallbackController

  def index(conn, params) do
    entries =
      Tools.list_registry_entries(
        limit: parse_limit(Map.get(params, "limit", "100")),
        enabled: parse_enabled(Map.get(params, "enabled"))
      )
      |> Enum.map(&Tools.serialize_registry_entry/1)

    json(conn, %{data: entries})
  end

  def sync(conn, _params) do
    result = Manager.sync_tool_registry()

    json(conn, %{
      data: %{
        synced: length(result.ok),
        errors: length(result.error)
      }
    })
  end

  def update(conn, %{"server_id" => server_id, "tool_name" => tool_name} = params) do
    attrs = Map.take(params, update_fields())

    with {:ok, entry} <- Tools.update_registry_entry(server_id, tool_name, attrs) do
      conn
      |> put_status(:accepted)
      |> json(%{data: Tools.serialize_registry_entry(entry)})
    end
  end

  defp update_fields do
    ~w(description input_schema risk_tier requires_confirmation retryable timeout_ms enabled health_status metadata)
  end

  defp parse_enabled(nil), do: nil
  defp parse_enabled("true"), do: true
  defp parse_enabled("false"), do: false
  defp parse_enabled(value) when is_boolean(value), do: value
  defp parse_enabled(_value), do: nil

  defp parse_limit(value) when is_integer(value), do: min(max(value, 1), 200)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> parse_limit(int)
      :error -> 100
    end
  end
end
