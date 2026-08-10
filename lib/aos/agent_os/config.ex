defmodule AOS.AgentOS.Config do
  @moduledoc """
  Small adapter around application/runtime configuration.
  """

  @app :aos

  def get(key, default \\ nil), do: Application.get_env(@app, key, default)

  def runtime_type, do: get(:agent_runtime_type, :api)
  def llm_provider, do: get(:llm_provider)
  def api_key, do: get(:api_key)
  def agent_model, do: get(:agent_model)
  def agent_base_url, do: get(:agent_base_url)
  def agent_api_key, do: get(:agent_api_key)
  def agent_local_model, do: get(:agent_local_model)
  def cliproxy_api?, do: get(:cliproxy_api) == true
  def architect_max_retries, do: get(:architect_max_retries, 1)
  def domain_success_cap, do: get(:domain_success_cap, 1000)
  def failed_retention_days, do: get(:failed_retention_days, 1)
  def success_retention_days, do: get(:success_retention_days, 30)
  def default_autonomy_level, do: get(:default_autonomy_level, "supervised")
  def api_rate_limit, do: get(:api_rate_limit, {60, 60_000})
  def evolution_enabled?, do: get(:evolution_enabled, true) == true
  def evolution_mutation_threshold, do: get(:evolution_mutation_threshold, 0.7)
  def evolution_archive_min_usage, do: get(:evolution_archive_min_usage, 5)
  def evolution_archive_success_rate, do: get(:evolution_archive_success_rate, 0.2)
  def evolution_experiment_min_usage, do: get(:evolution_experiment_min_usage, 3)
  def evolution_exploration_rate, do: get(:evolution_exploration_rate, 0.1)

  def evolution_quality_evaluator_enabled?,
    do: get(:evolution_quality_evaluator_enabled, false) == true

  def max_refinement_attempts, do: get(:max_refinement_attempts, 3)

  def dag_engine_enabled?, do: get(:dag_engine_enabled, false) == true

  def sync_async_executions?, do: get(:sync_async_executions, false) == true

  def slack_response_dispatcher,
    do: get(:slack_response_dispatcher) || AOS.AgentOS.Channels.SlackResponder

  def llm_pricing, do: get(:llm_pricing, %{})

  def workspace_root do
    get(:workspace_root, File.cwd!())
    |> Path.expand()
  end

  def base_url do
    get(:base_url, "http://localhost:4000")
    |> to_string()
    |> String.trim_trailing("/")
  end
end
