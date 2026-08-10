defmodule AOS.AgentOS.Harness.EntropyAuditor do
  @moduledoc "Audits repository hygiene against explicit golden principles."

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Harness.Manifest

  def audit(root \\ nil, opts \\ []) do
    root = Path.expand(root || Config.workspace_root())

    principles_path =
      Keyword.get(opts, :principles_path, Path.join(root, "harness/golden_principles.json"))

    with {:ok, principles} <- load_principles(principles_path) do
      findings = Enum.flat_map(principles, &check_principle(root, &1))
      errors = Enum.filter(findings, &(&1.severity == "error"))

      %{
        status: if(errors == [], do: "passed", else: "failed"),
        findings: findings,
        checked_at: DateTime.utc_now(),
        root: root
      }
    else
      {:error, reason} ->
        %{
          status: "failed",
          findings: [%{severity: "error", rule: "principles", message: inspect(reason)}]
        }
    end
  end

  def audit_manifest(root, manifest) do
    entropy = Manifest.get(manifest, :entropy, %{})

    if Manifest.get(entropy, :enabled, true) == true do
      path = Manifest.get(entropy, :principles_path, "harness/golden_principles.json")
      audit(root, principles_path: Path.expand(path, root))
    else
      %{status: "skipped", findings: []}
    end
  end

  defp load_principles(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode(content)
      {:error, reason} -> {:error, {:principles_unreadable, reason}}
    end
  end

  defp check_principle(root, %{"type" => "required_files"} = rule) do
    rule
    |> Map.get("paths", [])
    |> Enum.reject(&File.exists?(Path.join(root, &1)))
    |> Enum.map(&finding(rule, "required file missing: #{&1}"))
  end

  defp check_principle(root, %{"type" => "forbidden_files"} = rule) do
    roots = Map.get(rule, "roots", ["."])
    paths = Map.get(rule, "paths", [])

    paths
    |> Enum.flat_map(fn pattern ->
      Enum.flat_map(roots, fn source_root ->
        Path.wildcard(Path.join([root, source_root, "**", pattern])) ++
          Path.wildcard(Path.join([root, source_root, pattern]))
      end)
    end)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&finding(rule, "forbidden file found: #{Path.relative_to(&1, root)}"))
  end

  defp check_principle(root, %{"type" => "forbidden_regex"} = rule) do
    regex = Regex.compile!(Map.fetch!(rule, "pattern"))
    roots = Map.get(rule, "roots", ["."])

    roots
    |> Enum.flat_map(fn source_root ->
      Path.wildcard(Path.join([root, source_root, "**", "*.ex"]))
    end)
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} ->
          if Regex.match?(regex, content),
            do: [finding(rule, "forbidden pattern found: #{Path.relative_to(path, root)}")],
            else: []

        _ ->
          []
      end
    end)
  end

  defp check_principle(_root, _rule), do: []

  defp finding(rule, message),
    do: %{
      rule: Map.get(rule, "id", "unknown"),
      severity: Map.get(rule, "severity", "warning"),
      message: message
    }
end
