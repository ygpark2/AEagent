defmodule AOS.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias AOS.AgentOS.ConfigValidator
  alias AOS.AgentOS.Core.MemoryManager
  alias AOS.AgentOS.MCP.Manager
  alias AOS.AgentOS.Orchestration.MetaCoordinator
  alias AOS.AgentOS.Runtime.{AIPool, AIRuntime, Scheduler, SessionSupervisor}
  alias AOS.AgentOS.Goals.Processor, as: GoalProcessor
  alias AOS.AgentOS.TaskSupervisor
  alias AOS.Repo

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    # Run any migrations that haven't been run in single-binary deployments.
    if Application.get_env(:aos, :auto_migrate, false) do
      {:ok, _} = EctoBootMigration.migrate(:aos)
    end

    ConfigValidator.validate!()
    setup_opentelemetry()

    children = [
      # Start the Ecto repository
      Repo,
      # Start the Telemetry supervisor
      AOS.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: AOS.PubSub},
      # Start the Endpoint (http/https)
      AOSWeb.Endpoint,
      # Start PromEx
      AOS.PromEx,
      # Start the Agent OS Session Supervisor
      SessionSupervisor,
      # Background tasks for API/CLI-triggered executions
      {Task.Supervisor, name: TaskSupervisor},
      # Durable event protocol for independent orchestrators
      MetaCoordinator,
      # Durable goal event processor
      GoalProcessor,
      # Periodic long-term memory retention and strategy pruning
      MemoryManager,
      # Start MCP Manager
      Manager,
      # Start the Autonomous Scheduler
      Scheduler,
      # Start Local AI Runtime
      AIRuntime,
      # Start FLAME pool for local AI inference
      {FLAME.Pool,
       name: AIPool, min: 0, max: 10, max_concurrency: 5, idle_shutdown_after: :timer.minutes(5)}
      # Start a worker by calling: AOS.Worker.start_link(arg)
      # {AOS.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp setup_opentelemetry do
    OpentelemetryPhoenix.setup(adapter: :cowboy2)
    OpentelemetryEcto.setup([:aos, Repo])
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    AOSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
