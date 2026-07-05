defmodule AOS.AgentOS.Tools.Catalog do
  @moduledoc false

  @internal_tool_metadata %{
    "ls" => %{risk_tier: "low", requires_confirmation: false, retryable: false},
    "read_file" => %{risk_tier: "low", requires_confirmation: false, retryable: false},
    "write_file" => %{risk_tier: "high", requires_confirmation: true, retryable: false},
    "execute_command" => %{risk_tier: "high", requires_confirmation: true, retryable: false},
    "fetch_url" => %{risk_tier: "medium", requires_confirmation: false, retryable: true},
    "web_search" => %{risk_tier: "medium", requires_confirmation: false, retryable: true},
    "grep_search" => %{risk_tier: "low", requires_confirmation: false, retryable: false},
    "replace" => %{risk_tier: "high", requires_confirmation: true, retryable: false},
    "list_codebase_structure" => %{
      risk_tier: "low",
      requires_confirmation: false,
      retryable: false
    }
  }

  def metadata_for("internal", tool_name),
    do: static_metadata_for("internal", tool_name)

  def metadata_for(_server_id, tool_name),
    do: static_metadata_for(nil, tool_name)

  def static_metadata_for("internal", tool_name),
    do: Map.get(@internal_tool_metadata, tool_name, default_metadata())

  def static_metadata_for(_server_id, _tool_name), do: default_metadata()

  defp default_metadata,
    do: %{risk_tier: "medium", requires_confirmation: false, retryable: false}
end
