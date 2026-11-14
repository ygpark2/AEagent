defmodule AOS.AgentOS.Tools.Registry do
  @moduledoc """
  DB-backed registry for MCP tool capabilities, health, and policy metadata.
  """

  import Ecto.Query

  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Tools.Catalog
  alias AOS.AgentOS.Tools.RegistryEntry
  alias AOS.Repo

  @default_limit 200
  @circuit_breaker_threshold 3

  def get_entry(server_id, tool_name) when is_atom(server_id) or is_atom(tool_name) do
    get_entry(to_string(server_id), to_string(tool_name))
  end

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

  def tool_available?(server_id, tool_name) when is_atom(server_id) or is_atom(tool_name) do
    tool_available?(to_string(server_id), to_string(tool_name))
  end

  def tool_available?(server_id, tool_name) do
    case get_entry(server_id, tool_name) do
      %RegistryEntry{enabled: false} -> false
      %RegistryEntry{health_status: "unavailable"} -> false
      %RegistryEntry{} -> true
      nil -> true
    end
  end

  def record_tool_result(server_id, tool_name, result)
      when is_atom(server_id) or is_atom(tool_name) do
    record_tool_result(to_string(server_id), to_string(tool_name), result)
  end

  def record_tool_result(server_id, tool_name, result) do
    case get_or_create_entry(server_id, tool_name) do
      {:ok, entry} ->
        record_for_entry(entry, result)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  def health_summary do
    entries = list_entries(limit: 1000)
    counts = count_by_status(entries)

    %{
      summary: counts,
      healthy: counts.healthy,
      unavailable: counts.unavailable,
      degraded: counts.degraded,
      unknown: counts.unknown,
      tools: Enum.map(entries, &serialize/1)
    }
  end

  defp count_by_status(entries) do
    Enum.reduce(
      entries,
      %{healthy: 0, unavailable: 0, degraded: 0, unknown: 0},
      fn entry, acc ->
        status = String.to_atom(entry.health_status || "unknown")
        Map.update(acc, status, 1, &(&1 + 1))
      end
    )
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
        attrs = maybe_reset_failures(entry, attrs)

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

  defp get_or_create_entry(server_id, tool_name) do
    case get_entry(server_id, tool_name) do
      %RegistryEntry{} = entry ->
        {:ok, entry}

      nil ->
        static = Catalog.static_metadata_for(server_id, tool_name)

        attrs = %{
          server_id: server_id,
          tool_name: tool_name,
          input_schema: %{},
          risk_tier: static.risk_tier,
          requires_confirmation: static.requires_confirmation,
          retryable: static.retryable,
          timeout_ms: static.timeout_ms,
          enabled: true,
          health_status: "healthy",
          metadata: %{}
        }

        %RegistryEntry{}
        |> RegistryEntry.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp record_for_entry(%RegistryEntry{} = entry, result) do
    if success_result?(result) do
      handle_tool_success(entry)
    else
      handle_tool_failure(entry, extract_error_reason(result))
    end
  end

  defp success_result?({:ok, _}), do: true
  defp success_result?(:ok), do: true
  defp success_result?(%{ok: true}), do: true
  defp success_result?(%{status: "succeeded"}), do: true
  defp success_result?(_), do: false

  defp extract_error_reason({:error, reason}), do: reason
  defp extract_error_reason(:error), do: "unknown error"
  defp extract_error_reason(%{error: reason}), do: reason
  defp extract_error_reason(%{content: [%{text: text} | _]}), do: text
  defp extract_error_reason(other), do: other

  defp handle_tool_success(%RegistryEntry{} = entry) do
    current_meta = entry.metadata || %{}
    meta = Map.put(current_meta, "consecutive_failures", 0)

    attrs = %{
      health_status: "healthy",
      last_health_check_at: DateTime.utc_now(),
      metadata: meta
    }

    update_entry(entry.server_id, entry.tool_name, attrs)
  end

  defp handle_tool_failure(%RegistryEntry{} = entry, reason) do
    current_meta = entry.metadata || %{}

    current_failures =
      Map.get(current_meta, "consecutive_failures") ||
        Map.get(current_meta, :consecutive_failures) || 0

    new_failures = current_failures + 1
    tripped? = new_failures >= @circuit_breaker_threshold

    new_status = if tripped?, do: "unavailable", else: entry.health_status || "healthy"

    meta =
      current_meta
      |> Map.put("consecutive_failures", new_failures)
      |> Map.put("last_error", inspect(reason))

    attrs = %{
      health_status: new_status,
      last_health_check_at: DateTime.utc_now(),
      metadata: meta
    }

    if tripped? and entry.health_status != "unavailable" do
      emit_circuit_breaker_tripped(entry, new_failures, reason)
    end

    update_entry(entry.server_id, entry.tool_name, attrs)
  end

  defp emit_circuit_breaker_tripped(%RegistryEntry{} = entry, failures, reason) do
    EventStore.append_event(%{
      event_type: "tool.circuit_breaker.tripped",
      source: "tool_registry",
      payload: %{
        "server_id" => entry.server_id,
        "tool_name" => entry.tool_name,
        "consecutive_failures" => failures,
        "reason" => inspect(reason)
      }
    })
  rescue
    _ -> :ok
  end

  defp maybe_reset_failures(entry, attrs) do
    status = Map.get(attrs, :health_status) || Map.get(attrs, "health_status")
    attrs_meta = Map.get(attrs, :metadata) || Map.get(attrs, "metadata")

    if status == "healthy" and not explicit_failures?(attrs_meta) do
      meta =
        (attrs_meta || entry.metadata || %{})
        |> Map.put("consecutive_failures", 0)

      if Map.has_key?(attrs, "health_status") do
        Map.put(attrs, "metadata", meta)
      else
        Map.put(attrs, :metadata, meta)
      end
    else
      attrs
    end
  end

  defp explicit_failures?(nil), do: false

  defp explicit_failures?(meta) when is_map(meta) do
    Map.has_key?(meta, "consecutive_failures") or Map.has_key?(meta, :consecutive_failures)
  end

  defp explicit_failures?(_), do: false

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
