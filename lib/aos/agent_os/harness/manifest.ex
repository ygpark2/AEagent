defmodule AOS.AgentOS.Harness.Manifest do
  @moduledoc "Loads and normalizes the explicit repository harness contract."

  alias AOS.AgentOS.Config

  @default %{
    "version" => 1,
    "name" => "aos-agent-harness",
    "budgets" => %{
      "max_context_chars" => 120_000,
      "max_tool_calls" => 40,
      "max_shell_commands" => 10,
      "max_high_risk_tools" => 5,
      "max_permission_denials" => 3
    },
    "tools" => %{"allow" => [], "deny" => []},
    "permissions" => %{
      "workspace_root" => nil,
      "require_approval_for" => ["high"]
    },
    "verification" => %{
      "enabled" => true,
      "profile" => "default",
      "commands" => [],
      "required" => false
    },
    "entropy" => %{"enabled" => true, "mode" => "report"},
    "tracing" => %{"version" => 1}
  }

  def default, do: @default

  def load(path \\ nil) do
    path = Path.expand(path || Config.harness_manifest_path(), Config.workspace_root())

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} when is_map(manifest) -> {:ok, deep_merge(@default, manifest)}
          {:ok, _other} -> {:error, :invalid_harness_manifest}
          {:error, reason} -> {:error, {:invalid_harness_manifest, reason}}
        end

      {:error, :enoent} ->
        {:ok, @default}

      {:error, reason} ->
        {:error, {:harness_manifest_unreadable, reason}}
    end
  end

  def for_context(context, opts \\ []) do
    with {:ok, manifest} <- load(Keyword.get(opts, :manifest_path)),
         overrides <- Map.get(context, :harness, %{}),
         overrides <- if(is_map(overrides), do: overrides, else: %{}),
         manifest <- deep_merge(manifest, overrides),
         option_manifest <- Keyword.get(opts, :harness_manifest, %{}),
         option_manifest <- if(is_map(option_manifest), do: option_manifest, else: %{}),
         manifest <- deep_merge(manifest, option_manifest) do
      {:ok, enrich_task_spec(normalize_keys(manifest), context, opts)}
    end
  end

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  def get(_map, _key, default), do: default

  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  def deep_merge(_left, right), do: right

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), normalize_keys(item)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp enrich_task_spec(manifest, context, opts) do
    task_spec = %{
      "task" => Map.get(context, :task, get(manifest, :task, "")),
      "success_criteria" =>
        Keyword.get(opts, :success_criteria) ||
          Map.get(context, :success_criteria) ||
          get(manifest, :success_criteria, %{}),
      "constraints" => Keyword.get(opts, :constraints) || Map.get(context, :constraints, %{})
    }

    manifest
    |> Map.put("task_spec", task_spec)
    |> Map.put("workspace_root", Config.workspace_root())
  end
end
