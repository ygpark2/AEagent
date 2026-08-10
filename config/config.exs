import Config

# Load the environment variables from the appropriate .env file.
env =
  Mix.env()
  |> case do
    :prod -> ""
    env -> "-#{env}"
  end

try do
  # In case .env file does not exist.
  File.stream!("./.env#{env}")
  # Remove excess whitespace
  |> Stream.map(&String.trim_trailing/1)
  # Loop through each line
  |> Enum.each(fn line ->
    line
    # Split on *first* "=" (equals sign)
    |> String.split("=", parts: 2)
    # stackoverflow.com/q/33055834/1148249
    |> Enum.reduce(fn value, key ->
      # Skip all comments
      if key |> String.starts_with?("#") == false do
        # Set each environment variable
        System.put_env(key, value)
      end
    end)
  end)
rescue
  _ ->
    if Mix.env() not in [:dev, :test] do
      IO.puts(
        IO.ANSI.yellow() <>
          "There was no `.env#{env}` file found. Please ensure the required environment variables have been set." <>
          IO.ANSI.reset()
      )
    end
end

admin_users = System.get_env("ADMIN_USERS") || "[]"

old_admin_users = System.get_env("ADMIN_USERS_OLD") || admin_users
admin_password_hash = System.get_env("ADMIN_PASSWORD_HASH")

default_secret = fn env_name, dev_default ->
  case Mix.env() do
    env when env in [:dev, :test] ->
      System.get_env(env_name) || dev_default

    _env ->
      System.get_env(env_name) || raise("#{env_name} must be set")
  end
end

known_atom = fn env_name, default, allowed ->
  value = System.get_env(env_name) || default

  case Enum.find(allowed, &(to_string(&1) == value)) do
    nil -> raise("#{env_name} must be one of: #{Enum.map_join(allowed, ", ", &to_string/1)}")
    atom -> atom
  end
end

integer_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> parsed
        _ -> raise("#{env_name} must be a non-negative integer")
      end
  end
end

float_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case Float.parse(value) do
        {parsed, ""} when parsed >= 0.0 -> parsed
        _ -> raise("#{env_name} must be a non-negative number")
      end
  end
end

boolean_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    value ->
      case String.downcase(value) do
        normalized when normalized in ["true", "1", "yes", "on"] -> true
        normalized when normalized in ["false", "0", "no", "off"] -> false
        _normalized -> raise("#{env_name} must be true or false")
      end
  end
end

config :aos,
  admin_users: admin_users,
  admin_auth_provider: AOS.Admin.Credentials.EnvProvider,
  admin_password:
    System.get_env("ADMIN_PASSWORD") ||
      if(admin_password_hash, do: nil, else: default_secret.("ADMIN_PASSWORD", "admin")),
  admin_password_hash: admin_password_hash,
  admin_username: System.get_env("ADMIN_USERNAME") || "admin",
  ecto_repos: [AOS.Repo],
  encryption_keys: System.get_env("ENCRYPTION_KEYS"),
  env: Mix.env(),
  namespace: AOS,
  old_admin_users: old_admin_users,
  secure_cookies: false,
  api_key: default_secret.("AOS_API_KEY", "dev-aos-api-key"),
  agent_api_key: default_secret.("AGENT_API_KEY", "my-factory-api-key"),
  agent_base_url: System.get_env("AGENT_BASE_URL") || "http://localhost:8317/v1beta",
  agent_model: System.get_env("AGENT_MODEL") || "models/gemini-3-pro-preview",
  llm_provider: nil,
  # :api or :local
  agent_runtime_type: known_atom.("AGENT_RUNTIME_TYPE", "api", [:api, :local]),
  agent_local_model: System.get_env("AGENT_LOCAL_MODEL") || "google/gemma-2-2b-it",
  database_path: System.get_env("DATABASE_PATH") || "priv/repo/aos_dev.db",
  active_profile: known_atom.("AGENT_PROFILE", "jobdori", [:jobdori, :default]),
  cliproxy_api: System.get_env("CLIPROXYAPI") == "true",
  domain_success_cap: 1000,
  failed_retention_days: integer_env.("FAILED_RETENTION_DAYS", 1),
  success_retention_days: integer_env.("SUCCESS_RETENTION_DAYS", 30),
  api_rate_limit:
    {integer_env.("API_RATE_LIMIT_REQUESTS", 60),
     integer_env.("API_RATE_LIMIT_WINDOW_MS", 60_000)},
  evolution_enabled: boolean_env.("EVOLUTION_ENABLED", true),
  evolution_mutation_threshold: float_env.("EVOLUTION_MUTATION_THRESHOLD", 0.7),
  evolution_archive_min_usage: integer_env.("EVOLUTION_ARCHIVE_MIN_USAGE", 5),
  evolution_archive_success_rate: float_env.("EVOLUTION_ARCHIVE_SUCCESS_RATE", 0.2),
  evolution_experiment_min_usage: integer_env.("EVOLUTION_EXPERIMENT_MIN_USAGE", 3),
  evolution_exploration_rate: float_env.("EVOLUTION_EXPLORATION_RATE", 0.1),
  evolution_quality_evaluator_enabled: boolean_env.("EVOLUTION_QUALITY_EVALUATOR_ENABLED", false),
  architect_max_retries: 1,
  max_refinement_attempts: integer_env.("MAX_REFINEMENT_ATTEMPTS", 3),
  dag_engine_enabled: boolean_env.("DAG_ENGINE_ENABLED", false),
  workspace_root: File.cwd!(),
  default_autonomy_level: System.get_env("DEFAULT_AUTONOMY_LEVEL") || "supervised",
  webhook_shared_secret: default_secret.("WEBHOOK_SHARED_SECRET", "dev-webhook-secret"),
  slack_shared_secret: default_secret.("SLACK_SHARED_SECRET", "dev-slack-secret"),
  slack_signing_secret: default_secret.("SLACK_SIGNING_SECRET", "dev-slack-signing-secret"),
  max_agent_loops: 5,
  max_agent_cost_usd: 5.0,
  session_history_recent_turns: 6,
  session_history_summary_chars: 1600,
  llm_pricing: %{
    "gemini" => %{input_per_1k: 0.003, output_per_1k: 0.006},
    "gpt" => %{input_per_1k: 0.005, output_per_1k: 0.015},
    "claude" => %{input_per_1k: 0.008, output_per_1k: 0.024}
  },
  skill_permission_tools: %{
    "file_read" => ["ls", "read_file", "grep_search", "list_codebase_structure"],
    "file_write" => ["write_file", "replace"],
    "shell_exec" => ["execute_command"],
    "web_search" => ["web_search"],
    "web_fetch" => ["fetch_url"]
  },
  mcp_servers:
    %{
      # 예시: 파일시스템 MCP 서버 (설치되어 있어야 함)
      # filesystem: [
      #   command: "npx",
      #   args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/ygpark2/pjt/projects/coagent"]
      # ]
    }

# Configures the endpoint
config :aos, AOSWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r{priv/gettext/.*(po)$},
      ~r{priv/static/.*(js|css|png|jpeg|jpg|gif|svg|json)$},
      ~r{priv/static/cover/excoveralls.html$},
      ~r{priv/static/swagger.json$},
      ~r{lib/aos_web/controllers/.*(ex)$},
      ~r{lib/aos_web/controllers/v4/.*(ex)$},
      ~r{lib/aos_web/plugs/.*(ex)$},
      ~r{lib/aos_web/swagger/.*(ex)$},
      ~r{lib/aos_web/templates/.*(eex)$},
      ~r{lib/aos_web/views/.*(ex)$}
    ]
  ],
  pubsub_server: AOS.PubSub,
  reloadable_compilers: [:gettext, :phoenix, :elixir, :phoenix_swagger],
  render_errors: [view: AOSWeb.ErrorView, accepts: ~w(json json-api), layout: false],
  url: [host: "localhost"]

# Configure Phoenix Swagger
config :aos, :phoenix_swagger,
  swagger_files: %{
    "priv/static/swagger.json" => [
      router: AOSWeb.Router
    ]
  }

# Ensure Phoenix Swagger uses Jason instead of Poison
config :phoenix_swagger, json_library: Jason

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :format_encoders, "json-api": Jason

config :mime, :types, %{"application/vnd.api+json" => ["json-api"]}

config :ja_serializer, key_format: :camel_cased

# OpenTelemetry Configuration
config :opentelemetry,
  resource: [
    service: [name: "aeagent"]
  ],
  span_processor: {:otel_span_processor_batch, %{}},
  exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4318",
  otlp_headers: [
    {"x-honeycomb-team", System.get_env("HONEYCOMB_API_KEY") || ""},
    {"x-honeycomb-dataset", "aeagent"}
  ]

# Configure the email checker (for email validation).
config :email_checker,
  default_dns: :system,
  also_dns: [],
  validations: [EmailChecker.Check.Format, EmailChecker.Check.MX],
  smtp_retries: 2,
  timeout_milliseconds: 5000

import_config "#{Mix.env()}.exs"

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  default: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.0",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
