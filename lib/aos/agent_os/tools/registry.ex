defmodule AOS.AgentOS.Tools.Registry do
  @moduledoc """
  DB-backed registry for MCP tool capabilities, health, and policy metadata.
  """

  import Ecto.Query

  alias AOS.AgentOS.Tools.Catalog
  alias AOS.AgentOS.Tools.RegistryEntry
  alias AOS.Repo

  @default_limit 200

  def get_entry(server_id, tool_name),
    do: Repo.get_by(RegistryEntry, server_id: server_id, tool_name: tool_name)

  def list_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    enabled = Keyword.get(opts, :enabled)

    RegistryEntry
    |> maybe_filter_enabled(enabled)
    |> order_by([e], asc: e.server_id, asc: e.tool_name)
    |> limit(^limit)
    |> Repo.all()
  end

  def metadata_for(server_id, tool_name) do
    case get_entry(server_id, tool_name) do
      %RegistryEntry{} = entry -> metadata_from_entry(entry)
      nil -> Catalog.static_metadata_for(server_id, tool_name)
    end
  end

  def tool_enabled?(server_id, tool_name) do
    case get_entry(server_id, tool_name) do
      %RegistryEntry{enabled: enabled} -> enabled
      nil -> true
    end
  end

  def upsert_from_spec(%{} = tool_spec) do
    now = DateTime.utc_now()
    server_id = Map.fetch!(tool_spec, "server_id")
    tool_name = Map.fetch!(tool_spec, "name")
    static = Catalog.static_metadata_for(server_id, tool_name)

    attrs = %{
      server_id: server_id,
      tool_name: tool_name,
      description: Map.get(tool_spec, "description"),
      input_schema: Map.get(tool_spec, "inputSchema", %{}),
      risk_tier: Map.get(tool_spec, "riskTier", static.risk_tier),
      requires_confirmation:
        Map.get(tool_spec, "requiresConfirmation", static.requires_confirmation),
      retryable: Map.get(tool_spec, "retryable", static.retryable),
      timeout_ms: Map.get(tool_spec, "timeoutMs", 60_000),
      health_status: "healthy",
      last_seen_at: now,
      metadata: %{"source" => "mcp_sync"}
    }

    case get_entry(server_id, tool_name) do
      nil ->
        %RegistryEntry{}
        |> RegistryEntry.changeset(Map.put(attrs, :enabled, true))
        |> Repo.insert()

      %RegistryEntry{} = entry ->
        entry
        |> RegistryEntry.changeset(attrs)
        |> Repo.update()
    end
  end

  def sync_tools(tool_specs) when is_list(tool_specs) do
    tool_specs
    |> Enum.map(&upsert_from_spec/1)
    |> split_results()
  end

  def update_entry(server_id, tool_name, attrs) do
    case get_entry(server_id, tool_name) do
      nil ->
        {:error, :not_found}

      %RegistryEntry{} = entry ->
        entry
        |> RegistryEntry.changeset(attrs)
        |> Repo.update()
    end
  end

  def mark_health(server_id, tool_name, health_status, metadata \\ %{}) do
    update_entry(server_id, tool_name, %{
      health_status: health_status,
      last_health_check_at: DateTime.utc_now(),
      metadata: metadata
    })
  end

  def serialize(%RegistryEntry{} = entry) do
    %{
      id: entry.id,
      server_id: entry.server_id,
      tool_name: entry.tool_name,
      description: entry.description,
      input_schema: entry.input_schema,
      risk_tier: entry.risk_tier,
      requires_confirmation: entry.requires_confirmation,
      retryable: entry.retryable,
      timeout_ms: entry.timeout_ms,
      enabled: entry.enabled,
      health_status: entry.health_status,
      last_seen_at: entry.last_seen_at,
      last_health_check_at: entry.last_health_check_at,
      metadata: entry.metadata,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  defp metadata_from_entry(%RegistryEntry{} = entry) do
    %{
      risk_tier: entry.risk_tier,
      requires_confirmation: entry.requires_confirmation,
      retryable: entry.retryable,
      timeout_ms: entry.timeout_ms,
      enabled: entry.enabled,
      health_status: entry.health_status
    }
  end

  defp split_results(results) do
    Enum.reduce(results, %{ok: [], error: []}, fn
      {:ok, entry}, acc -> %{acc | ok: [entry | acc.ok]}
      {:error, reason}, acc -> %{acc | error: [reason | acc.error]}
    end)
  end

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled), do: where(query, [e], e.enabled == ^enabled)
end
