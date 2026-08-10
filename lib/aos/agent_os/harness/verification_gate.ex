defmodule AOS.AgentOS.Harness.VerificationGate do
  @moduledoc "Runs deterministic test/lint/build commands before an episode can succeed."

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Harness.{Episode, Manifest}
  alias AOS.Runtime.CommandRunner

  @default_allowed_commands ~w(mix make git npm pnpm yarn cargo go pytest elixir erlc)

  def verify(context, opts \\ []) do
    manifest =
      Keyword.get(opts, :manifest) || Map.get(context, :harness_manifest) || Manifest.default()

    verification = selected_verification(manifest)
    enabled? = Manifest.get(verification, :enabled, true) == true
    commands = Manifest.get(verification, :commands, [])

    cond do
      not Config.harness_enabled?() ->
        report = %{status: "skipped", reason: "harness_disabled"}
        record(context, report)
        {:ok, report, Map.put(context, :harness_verification, report)}

      not enabled? or commands == [] ->
        report = %{status: "skipped", reason: "no_verification_commands"}
        record(context, report)
        {:ok, report, Map.put(context, :harness_verification, report)}

      true ->
        report = run_commands(commands, verification)
        record(context, report)

        if report.status == "passed" or Manifest.get(verification, :required, false) != true do
          {:ok, report, Map.put(context, :harness_verification, report)}
        else
          reason = {:verification_failed, report}
          {:error, reason, report, Map.put(context, :harness_verification, report)}
        end
    end
  end

  defp selected_verification(manifest) do
    verification = Manifest.get(manifest, :verification, %{})
    profile_name = Manifest.get(verification, :profile, "default")
    profiles = Manifest.get(verification, :profiles, %{})
    profile = Manifest.get(profiles, profile_name, %{})
    Manifest.deep_merge(verification, profile)
  end

  defp run_commands(commands, verification) do
    allowed =
      Manifest.get(verification, :allowed_commands, @default_allowed_commands)
      |> Enum.map(&to_string/1)

    started_at = System.monotonic_time(:millisecond)

    results =
      Enum.map(commands, fn command_spec ->
        run_command(command_spec, allowed, verification)
      end)

    failed = Enum.filter(results, &(&1.status == "failed"))

    %{
      status: if(failed == [], do: "passed", else: "failed"),
      commands: results,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      checked_at: DateTime.utc_now()
    }
  end

  defp run_command(command_spec, allowed, verification) do
    {command, args, timeout_ms} = normalize_command(command_spec, verification)

    cond do
      command not in allowed ->
        %{
          command: command,
          args: args,
          status: "failed",
          exit_code: 126,
          output: "command_not_allowed"
        }

      true ->
        case CommandRunner.run(command, args,
               cd: Config.workspace_root(),
               timeout_ms: timeout_ms,
               output_limit: 32_000
             ) do
          {:ok, result} ->
            %{
              command: command,
              args: args,
              status: if(result.exit_code == 0, do: "passed", else: "failed"),
              exit_code: result.exit_code,
              output: result.output,
              timed_out?: Map.get(result, :timed_out?, false),
              truncated?: Map.get(result, :truncated?, false)
            }

          {:error, reason} ->
            %{
              command: command,
              args: args,
              status: "failed",
              exit_code: 127,
              output: inspect(reason)
            }
        end
    end
  end

  defp normalize_command(command, verification) when is_binary(command),
    do: {command, [], timeout_for(verification)}

  defp normalize_command(%{} = command, verification) do
    {
      Manifest.get(command, :command, ""),
      Manifest.get(command, :args, []) |> Enum.map(&to_string/1),
      Manifest.get(command, :timeout_ms, timeout_for(verification))
    }
  end

  defp normalize_command(_command, verification), do: {"", [], timeout_for(verification)}

  defp timeout_for(verification),
    do: Manifest.get(verification, :timeout_ms, Config.harness_verification_timeout_ms())

  defp record(context, report) do
    if execution_id = Map.get(context, :execution_id) do
      Episode.trace(execution_id, "verification", report.status, report,
        idempotency_key:
          "verification:#{report.status}:#{:erlang.phash2(Map.delete(report, :checked_at))}"
      )
    end

    :ok
  end
end
