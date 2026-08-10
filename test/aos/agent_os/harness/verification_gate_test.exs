defmodule AOS.AgentOS.Harness.VerificationGateTest do
  use ExUnit.Case, async: false

  alias AOS.AgentOS.Harness.{Manifest, VerificationGate}

  test "runs an allowlisted deterministic verification command" do
    manifest =
      Manifest.deep_merge(Manifest.default(), %{
        "verification" => %{
          "required" => true,
          "commands" => [
            %{"command" => "elixir", "args" => ["-e", "IO.puts(\"harness-ok\")"]}
          ]
        }
      })

    assert {:ok, report, context} =
             VerificationGate.verify(%{harness_manifest: manifest}, manifest: manifest)

    assert report.status == "passed"
    assert [%{status: "passed", output: output}] = report.commands
    assert output =~ "harness-ok"
    assert context.harness_verification.status == "passed"
  end

  test "skips a profile with no commands" do
    assert {:ok, %{status: "skipped", reason: "no_verification_commands"}, _context} =
             VerificationGate.verify(%{harness_manifest: Manifest.default()})
  end

  test "returns a blocking error when a required command fails" do
    manifest =
      Manifest.deep_merge(Manifest.default(), %{
        "verification" => %{
          "required" => true,
          "commands" => [%{"command" => "elixir", "args" => ["-e", "System.halt(2)"]}]
        }
      })

    assert {:error, {:verification_failed, %{status: "failed"}}, _report, context} =
             VerificationGate.verify(%{harness_manifest: manifest})

    assert context.harness_verification.status == "failed"
  end
end
