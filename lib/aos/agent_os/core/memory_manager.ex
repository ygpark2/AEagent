defmodule AOS.AgentOS.Core.MemoryManager do
  @moduledoc """
  Manages the Long-term Memory by cleaning up old or irrelevant data.
  Ensures the DB doesn't grow indefinitely.
  """
  use GenServer
  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Core.{MemoryRetentionPolicy, MemoryStore, NodeRegistry}
  alias AOS.AgentOS.Evolution.StrategyRegistry
  alias AOS.AgentOS.Harness.EntropyAuditor
  require Logger

  # Once a day
  @cleanup_interval 24 * 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.info("[MemoryManager] Starting scheduled memory cleanup...")

    # 1. Delete failed executions older than 24 hours
    delete_failed_executions()

    # 2. Cleanup very old logs (more than 30 days)
    cleanup_old_successes()

    # 3. Cap successful records per domain (The new feature)
    cap_domain_successes()

    # 4. Archive low-performing evolved strategies
    prune_strategies()

    # 5. Audit repository entropy against the explicit harness contract
    audit_repository_entropy()

    schedule_cleanup()
    {:noreply, state}
  end

  defp delete_failed_executions do
    count =
      DateTime.utc_now()
      |> MemoryRetentionPolicy.failed_cutoff()
      |> MemoryStore.delete_failed_executions_before()

    Logger.info("[MemoryManager] Deleted #{count} failed executions (Old).")
  end

  defp cleanup_old_successes do
    count =
      DateTime.utc_now()
      |> MemoryRetentionPolicy.success_log_cutoff()
      |> MemoryStore.clear_success_logs_before()

    Logger.info("[MemoryManager] Compacted #{count} old successful executions (Logs cleared).")
  end

  defp cap_domain_successes do
    cap = Config.domain_success_cap()
    domains = NodeRegistry.all_domains()

    Enum.each(domains, fn domain ->
      domain_str = to_string(domain)

      count = MemoryStore.successful_count_for_domain(domain_str)
      over_count = MemoryRetentionPolicy.domain_overflow_count(count, cap)

      if over_count > 0 do
        Logger.info(
          "[MemoryManager] Domain '#{domain_str}' has #{count} records. Capping to #{cap} (Deleting #{over_count} oldest)."
        )

        deleted = MemoryStore.delete_oldest_successes_for_domain(domain_str, over_count)

        Logger.info(
          "[MemoryManager] Successfully removed #{deleted} overflow records for '#{domain_str}'."
        )
      end
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp prune_strategies do
    result = StrategyRegistry.prune()
    Logger.info("[MemoryManager] Archived #{result.archived} low-performing strategies.")
  end

  defp audit_repository_entropy do
    if Config.harness_entropy_audit_enabled?() do
      report = EntropyAuditor.audit(Config.workspace_root())

      if report.status == "passed" do
        Logger.info("[MemoryManager] Harness entropy audit passed.")
      else
        Logger.warning(
          "[MemoryManager] Harness entropy audit findings: #{inspect(report.findings)}"
        )
      end
    end
  end
end
