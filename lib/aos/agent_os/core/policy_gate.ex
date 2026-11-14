defmodule AOS.AgentOS.Core.PolicyGate do
  @moduledoc "Shared policy gate used by graph and DAG execution engines."

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Core.PolicyTrace
  alias AOS.AgentOS.Policies.{BudgetPolicy, DomainPolicy, SafetyPolicy}
  alias AOS.AgentOS.Tools.Permissions

  @active_policies [SafetyPolicy, BudgetPolicy, DomainPolicy]

  def check(context, node_id) do
    Enum.reduce_while(@active_policies, {:ok, context}, fn policy, {:ok, acc_context} ->
      case policy.check(acc_context, node_id) do
        {:ok, updated_context} ->
          trace(acc_context, policy, :allowed, node_id, nil)
          {:cont, {:ok, updated_context}}

        {:error, reason} ->
          trace(acc_context, policy, :blocked, node_id, reason)
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Validates a tool invocation against capability scopes, safe filesystem boundaries,
  and network domain allowlists. Emits structured `policy.allowed` or `policy.blocked` trace events.
  """
  def check_tool(context_or_opts, tool_name, args)
      when is_binary(tool_name) or is_atom(tool_name) do
    check_tool(context_or_opts, "internal", tool_name, args, [])
  end

  def check_tool(context_or_opts, server_id, tool_name, args, extra_opts \\ []) do
    opts = to_opts_map(context_or_opts, extra_opts)
    tool_name_str = to_string(tool_name)

    with :ok <- check_tool_scope(tool_name_str, opts),
         :ok <- check_path_boundary(tool_name_str, args, opts),
         :ok <- check_domain_boundary(tool_name_str, args, opts) do
      trace_tool(opts, server_id, tool_name_str, :allowed, nil)
      :ok
    else
      {:error, reason} ->
        trace_tool(opts, server_id, tool_name_str, :blocked, reason)
        {:error, reason}
    end
  end

  def blocking_reason?({:approval_required, _request}), do: true
  def blocking_reason?(reason) when reason in [:evaluation_required, :out_of_budget], do: true
  def blocking_reason?(reason) when reason in [:too_many_loops, :dangerous_intent], do: true
  def blocking_reason?(reason) when reason in [:dangerous_output, :dangerous_command], do: true

  def blocking_reason?(reason)
      when reason in [
             :unsafe_write_path,
             :unsafe_file_path,
             :unauthorized_domain,
             :scope_not_allowed
           ],
      do: true

  def blocking_reason?({:policy_blocked, _}), do: true

  def blocking_reason?({reason, _})
      when reason in [
             :unsafe_write_path,
             :unsafe_file_path,
             :unauthorized_domain,
             :scope_not_allowed
           ],
      do: true

  def blocking_reason?(_reason), do: false

  @path_keys ~w(path file filepath destination target)a ++
               ~w(path file filepath destination target)
  @url_keys ~w(url uri)a ++ ~w(url uri)

  defp check_tool_scope(tool_name, opts) do
    case get_opt(opts, :allowed_scopes) do
      scopes when is_list(scopes) and scopes != [] ->
        scope = Permissions.tool_scope(tool_name)
        validate_scope_match(scope, scopes)

      _ ->
        :ok
    end
  end

  defp validate_scope_match(nil, _scopes), do: :ok

  defp validate_scope_match(scope, scopes) do
    string_scopes = Enum.map(scopes, &to_string/1)

    if to_string(scope) in string_scopes do
      :ok
    else
      {:error, :scope_not_allowed}
    end
  end

  defp check_path_boundary(tool_name, args, opts) do
    scope = Permissions.tool_scope(tool_name)
    path = extract_path(args)

    cond do
      is_binary(path) and path != "" ->
        safe_paths = get_opt(opts, :safe_paths)
        workspace_root = get_opt(opts, :workspace_root) || Config.workspace_root()

        if path_allowed?(path, safe_paths, workspace_root) do
          :ok
        else
          {:error, :unsafe_file_path}
        end

      scope in ["file_read", "file_write"] and is_nil(path) ->
        :ok

      true ->
        :ok
    end
  end

  defp check_domain_boundary(tool_name, args, opts) do
    case get_opt(opts, :allowed_domains) do
      domains when is_list(domains) and domains != [] ->
        verify_url_domain(tool_name, extract_url(args), domains)

      _ ->
        :ok
    end
  end

  defp verify_url_domain(_tool_name, url, domains) when is_binary(url) and url != "" do
    if domain_allowed?(url, domains), do: :ok, else: {:error, :unauthorized_domain}
  end

  defp verify_url_domain(tool_name, _url, _domains) do
    scope = Permissions.tool_scope(tool_name)

    if scope in ["web_fetch"] or tool_name in ["fetch_url"] do
      {:error, :unauthorized_domain}
    else
      :ok
    end
  end

  defp path_allowed?(path, safe_paths, workspace_root)
       when is_list(safe_paths) and safe_paths != [] do
    expanded = Path.expand(path, workspace_root)

    Enum.any?(safe_paths, fn safe_root ->
      expanded_root = Path.expand(safe_root, workspace_root)
      inside_root?(expanded, expanded_root)
    end)
  end

  defp path_allowed?(path, _safe_paths, workspace_root) do
    expanded = Path.expand(path, workspace_root)
    inside_root?(expanded, Path.expand(workspace_root))
  end

  defp inside_root?(expanded_path, expanded_root) do
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp domain_allowed?(url, allowed_domains) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        downcased_host = String.downcase(host)

        Enum.any?(allowed_domains, fn domain ->
          downcased_domain = domain |> to_string() |> String.downcase()

          downcased_host == downcased_domain or
            String.ends_with?(downcased_host, "." <> downcased_domain)
        end)

      _ ->
        false
    end
  end

  defp extract_path(args) when is_map(args) do
    Enum.find_value(@path_keys, fn key ->
      case Map.get(args, key) do
        path when is_binary(path) and path != "" -> path
        _ -> nil
      end
    end)
  end

  defp extract_path(_), do: nil

  defp extract_url(args) when is_map(args) do
    Enum.find_value(@url_keys, fn key ->
      case Map.get(args, key) do
        url when is_binary(url) and url != "" -> url
        _ -> nil
      end
    end)
  end

  defp extract_url(_), do: nil

  defp to_opts_map(context_or_opts, extra_opts) do
    base =
      cond do
        is_map(context_or_opts) -> context_or_opts
        is_list(context_or_opts) -> Map.new(context_or_opts)
        true -> %{}
      end

    extra =
      cond do
        is_map(extra_opts) -> extra_opts
        is_list(extra_opts) -> Map.new(extra_opts)
        true -> %{}
      end

    Map.merge(base, extra)
  end

  defp get_opt(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_opt(_, _), do: nil

  defp trace(context, policy, decision, node_id, reason) do
    PolicyTrace.record(context, policy, decision,
      source: "policy_gate",
      node_id: node_id,
      reason: reason,
      input_summary: input_summary(context)
    )
  end

  defp trace_tool(opts, server_id, tool_name, decision, reason) do
    node_id = get_opt(opts, :node_id)

    PolicyTrace.record(opts, __MODULE__, decision,
      source: "policy_gate",
      node_id: node_id,
      tool_name: "#{server_id}__#{tool_name}",
      reason: reason,
      input_summary: %{
        "server_id" => to_string(server_id),
        "tool_name" => to_string(tool_name)
      }
    )
  end

  defp input_summary(context) do
    %{
      "domain" => stringify(Map.get(context, :domain)),
      "autonomy_level" => stringify(Map.get(context, :autonomy_level)),
      "loop_count" => context |> Map.get(:execution_history, []) |> length(),
      "cost_usd" => Map.get(context, :cost_usd) || Map.get(context, :estimated_cost)
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
