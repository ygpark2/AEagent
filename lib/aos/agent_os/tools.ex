defmodule AOS.AgentOS.Tools do
  @moduledoc """
  Normalizes tool execution metadata and persists tool audit logs.
  """
  alias AOS.AgentOS.Tools.{Permissions, Registry, ResultNormalizer}
  alias AOS.AgentOS.ToolUse.Store

  def metadata_for(server_id, tool_name), do: Registry.metadata_for(server_id, tool_name)

  def permitted_tools(all_tools, selected_skills),
    do:
      all_tools
      |> Enum.filter(&Registry.tool_enabled?(&1["server_id"], &1["name"]))
      |> Permissions.permitted_tools(selected_skills)

  def tool_permitted_for_skills?(server_id, tool_name, selected_skills),
    do: Permissions.tool_permitted_for_skills?(server_id, tool_name, selected_skills)

  def effective_tool_names(selected_skills), do: Permissions.effective_tool_names(selected_skills)

  def normalize_result(server_id, tool_name, args, metadata, decision, raw_result, attempts) do
    ResultNormalizer.normalize(
      server_id,
      tool_name,
      args,
      metadata,
      decision,
      raw_result,
      attempts
    )
  end

  def create_audit(attrs) do
    Store.create_audit(attrs)
  end

  def sync_registry(tool_specs), do: Registry.sync_tools(tool_specs)
  def list_registry_entries(opts \\ []), do: Registry.list_entries(opts)

  def update_registry_entry(server_id, tool_name, attrs),
    do: Registry.update_entry(server_id, tool_name, attrs)

  def serialize_registry_entry(entry), do: Registry.serialize(entry)

  def list_audits(execution_id) do
    Store.list_audits(execution_id)
  end

  def serialize_audit(audit), do: Store.serialize_audit(audit)
end
