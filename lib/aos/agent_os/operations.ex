defmodule AOS.AgentOS.Operations do
  @moduledoc """
  Operational diagnostics and metrics aggregation helpers.
  """
  alias AOS.AgentOS.{Config, Operations.Store}
  alias AOS.AgentOS.Operations.Config, as: OperationsConfig

  def doctor do
    db_ok? = Store.database_healthy?()

    %{
      status: overall_status(db_ok?),
      checks: %{
        database: db_ok?,
        endpoint_configured: OperationsConfig.endpoint_configured?(),
        task_supervisor: Process.whereis(AOS.AgentOS.TaskSupervisor) != nil,
        mcp_manager: Process.whereis(AOS.AgentOS.MCP.Manager) != nil
      },
      config: %{
        default_autonomy_level: Config.default_autonomy_level(),
        evolution: %{
          enabled: Config.evolution_enabled?(),
          mutation_threshold: Config.evolution_mutation_threshold(),
          max_refinement_attempts: Config.max_refinement_attempts(),
          archive_min_usage: Config.evolution_archive_min_usage(),
          archive_success_rate: Config.evolution_archive_success_rate(),
          experiment_min_usage: Config.evolution_experiment_min_usage(),
          exploration_rate: Config.evolution_exploration_rate(),
          quality_evaluator_enabled: Config.evolution_quality_evaluator_enabled?()
        },
        retention: %{
          failed_days: Config.failed_retention_days(),
          success_log_days: Config.success_retention_days(),
          domain_success_cap: Config.domain_success_cap()
        },
        workspace_root: Config.workspace_root(),
        agent_runtime_type: Config.runtime_type(),
        dag_engine_enabled: Config.dag_engine_enabled?()
      }
    }
  end

  def metrics_summary, do: Store.metrics_summary()

  defp overall_status(true), do: "ok"
  defp overall_status(false), do: "degraded"
end
