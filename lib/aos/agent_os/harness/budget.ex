defmodule AOS.AgentOS.Harness.Budget do
  @moduledoc "Per-task context, tool, shell, risk, and permission budget enforcement."

  alias AOS.AgentOS.Harness.Manifest

  def check_context(context) when is_map(context) do
    manifest = Map.get(context, :harness_manifest, Manifest.default())

    max_chars =
      positive_limit(
        Manifest.get(Manifest.get(manifest, :budgets, %{}), :max_context_chars, 120_000)
      )

    chars = context |> inspect(limit: :infinity, printable_limit: max_chars + 1) |> byte_size()

    if chars > max_chars,
      do: {:error, {:harness_budget_exceeded, :context_chars, chars, max_chars}},
      else: {:ok, context}
  end

  def before_tool(opts, server_id, tool_name, metadata) do
    manifest = Keyword.get(opts, :harness_manifest, Manifest.default())
    budgets = Manifest.get(manifest, :budgets, %{})
    tools = Manifest.get(manifest, :tools, %{})
    state = Keyword.get(opts, :harness_budget_state, %{})
    full_name = "#{server_id}__#{tool_name}"
    shell_command? = server_id == "internal" and tool_name in ["execute_command", "shell_exec"]
    allow = normalize_list(Manifest.get(tools, :allow, []))
    deny = normalize_list(Manifest.get(tools, :deny, []))

    cond do
      deny != [] and (tool_name in deny or full_name in deny) ->
        {:error, {:harness_permission_denied, full_name}}

      allow != [] and tool_name not in allow and full_name not in allow ->
        {:error, {:harness_permission_denied, full_name}}

      exceeds?(state, :tool_calls, budgets, :max_tool_calls) ->
        {:error, budget_error(:tool_calls, state, budgets, :max_tool_calls)}

      high_risk?(metadata) and exceeds?(state, :high_risk_tools, budgets, :max_high_risk_tools) ->
        {:error, budget_error(:high_risk_tools, state, budgets, :max_high_risk_tools)}

      shell_command? and exceeds?(state, :shell_commands, budgets, :max_shell_commands) ->
        {:error, budget_error(:shell_commands, state, budgets, :max_shell_commands)}

      exceeds?(state, :permission_denials, budgets, :max_permission_denials) ->
        {:error, budget_error(:permission_denials, state, budgets, :max_permission_denials)}

      true ->
        next_state =
          state
          |> increment(:tool_calls)
          |> maybe_increment(:shell_commands, shell_command?)
          |> maybe_increment(:high_risk_tools, high_risk?(metadata))
          |> Map.put(:last_tool, full_name)

        {:ok, Keyword.put(opts, :harness_budget_state, next_state)}
    end
  end

  def after_tool(opts, result) do
    state = Keyword.get(opts, :harness_budget_state, %{})

    if rejected?(result),
      do: Keyword.put(opts, :harness_budget_state, increment(state, :permission_denials)),
      else: opts
  end

  def initial_state,
    do: %{tool_calls: 0, shell_commands: 0, high_risk_tools: 0, permission_denials: 0}

  defp exceeds?(state, key, budgets, limit_key) do
    limit = Manifest.get(budgets, limit_key)
    is_integer(limit) and limit > 0 and Map.get(state, key, 0) >= limit
  end

  defp budget_error(key, state, budgets, limit_key) do
    {:harness_budget_exceeded, key, Map.get(state, key, 0), Manifest.get(budgets, limit_key)}
  end

  defp high_risk?(metadata), do: Manifest.get(metadata, :risk_tier, "low") in ["high", :high]

  defp rejected?(result), do: Manifest.get(result, :status) in ["rejected", :rejected]

  defp increment(state, key), do: Map.update(state, key, 1, &(&1 + 1))
  defp maybe_increment(state, _key, false), do: state
  defp maybe_increment(state, key, true), do: increment(state, key)

  defp positive_limit(value) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value), do: 120_000

  defp normalize_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_list(_value), do: []
end
