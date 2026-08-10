defmodule AOS.AgentOS.Harness.ManifestTest do
  use ExUnit.Case, async: true

  alias AOS.AgentOS.Harness.{Budget, EntropyAuditor, FailureAttribution, Manifest}

  test "merges task contract over repository defaults" do
    manifest =
      Manifest.deep_merge(Manifest.default(), %{
        "budgets" => %{"max_tool_calls" => 2},
        "task_spec" => %{"task" => "inspect"}
      })

    assert Manifest.get(Manifest.get(manifest, :budgets), :max_tool_calls) == 2
    assert Manifest.get(manifest, :name) == "aos-agent-harness"
    assert Manifest.get(Manifest.get(manifest, :task_spec), :task) == "inspect"
  end

  test "enforces shell and high-risk budgets per task" do
    manifest =
      Manifest.deep_merge(Manifest.default(), %{
        "budgets" => %{"max_shell_commands" => 1, "max_high_risk_tools" => 5}
      })

    opts = [harness_manifest: manifest, harness_budget_state: Budget.initial_state()]

    assert {:ok, next_opts} =
             Budget.before_tool(opts, "internal", "execute_command", %{risk_tier: "high"})

    assert {:error, {:harness_budget_exceeded, :shell_commands, 1, 1}} =
             Budget.before_tool(next_opts, "internal", "execute_command", %{risk_tier: "high"})
  end

  test "classifies verification and intervention failures consistently" do
    assert FailureAttribution.classify({:verification_failed, %{status: "failed"}}).category ==
             "verification_failed"

    assert FailureAttribution.classify({:approval_required, %{id: "request"}}).category ==
             "user_intervention_required"
  end

  test "audits the repository against golden principles" do
    report = EntropyAuditor.audit()

    assert report.status == "passed"
    assert report.findings == []
  end
end
