defmodule AOSWeb.Router do
  use AOSWeb, :router

  import Phoenix.LiveDashboard.Router
  import Phoenix.LiveView.Router

  alias AOSWeb.Swagger.Info

  pipeline :api_deserializer do
    plug JaSerializer.Deserializer
  end

  pipeline :api do
    plug :accepts, ["json", "json-api"]
    plug :fetch_session
    plug AOSWeb.Plugs.RateLimit, bucket: :api
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_root_layout, html: {AOSWeb.LayoutView, :app}
    plug :protect_from_forgery
  end

  pipeline :admin_auth do
    plug AOSWeb.Plugs.AdminAuth
  end

  pipeline :api_auth do
    plug AOSWeb.Plugs.ApiAuth
  end

  pipeline :no_prod do
    plug AOSWeb.Plugs.NoProd
  end

  pipeline :secure do
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :secure_no_csrf do
    plug :fetch_session
    plug :fetch_flash
    plug :put_secure_browser_headers
  end

  scope "/", AOSWeb do
    pipe_through [:browser, :admin_auth]

    # Root route now goes to the Agent Dashboard
    get "/", RedirectController, :to_agent
    live "/agent", AgentDashboardLive, :index
  end

  scope "/admin", AOSWeb do
    pipe_through [:browser]
    get "/login", AdminAuthController, :login
    post "/login", AdminAuthController, :authenticate
    get "/logout", AdminAuthController, :logout
  end

  scope "/admin", AOSWeb do
    pipe_through [:browser, :admin_auth]
    live "/skills", SkillAdminLive, :index
    live "/strategies", StrategyAdminLive, :index
  end

  scope "/api", AOSWeb, as: :api do
    pipe_through [:api, :api_deserializer]

    scope "/v1", V1, as: :v1 do
      post "/channels/slack/commands", SlackController, :create
      post "/channels/slack/interactions", SlackController, :interact
      post "/webhooks/executions", WebhookController, :create
    end
  end

  scope "/api", AOSWeb, as: :api do
    pipe_through [:api, :api_deserializer, :api_auth]

    scope "/v1", V1, as: :v1 do
      resources "/goals", GoalController, only: [:index, :show, :create, :update]
      post "/goals/:id/events", GoalController, :trigger
      get "/goals/:id/events", GoalController, :events
      get "/goals/:id/runs", GoalController, :runs
      post "/goals/:id/pause", GoalController, :pause
      post "/goals/:id/resume", GoalController, :resume
      post "/goals/:id/cancel", GoalController, :cancel
      post "/executions/:id/resume", ExecutionController, :resume
      post "/executions/:id/retry", ExecutionController, :retry
      get "/executions/:id/replay", ExecutionController, :replay
      post "/approvals/:id/approve", ApprovalController, :approve
      post "/approvals/:id/reject", ApprovalController, :reject
      post "/tools/registry/sync", ToolRegistryController, :sync
      patch "/tools/registry/:server_id/:tool_name", ToolRegistryController, :update
      post "/strategies/prune", StrategyController, :prune
      get "/strategies/:id/events", StrategyController, :events
      get "/strategies/:id/executions", StrategyController, :executions
      resources "/approvals", ApprovalController, only: [:index, :show]
      resources "/tools/registry", ToolRegistryController, only: [:index]
      resources "/strategies", StrategyController, only: [:index, :show]
      resources "/sessions", SessionController, only: [:index, :show]
      resources "/executions", ExecutionController, only: [:index, :show, :create]
    end
  end

  scope "/healthcheck", AOSWeb do
    pipe_through [:api, :api_deserializer]
    get "/", VersionController, :index
    get "/doctor", OperationsController, :doctor
    get "/metrics", OperationsController, :metrics
  end

  scope "/test_coverage", AOSWeb do
    pipe_through [:no_prod, :browser, :secure]
    get "/", TestCoverageController, :index
  end

  def swagger_info do
    Info.swagger_info()
  end

  scope "/" do
    scope "/api/swagger" do
      pipe_through [:browser]

      forward "/", PhoenixSwagger.Plug.SwaggerUI,
        otp_app: :aos,
        swagger_file: "swagger.json",
        disable_validator: true
    end

    scope "/dashboard" do
      pipe_through [:browser, :secure]

      live_dashboard "/", metrics: AOS.Telemetry
    end

    # Move documentation catch-all to the bottom and ensure it doesn't hijack root
    scope "/docs", AOSWeb do
      pipe_through [:no_prod, :browser]
      get "/*path", DocsController, :index
    end
  end
end
