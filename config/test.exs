import Config

application_port = 4002

# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database_path =
  System.get_env("DATABASE_PATH") ||
    "priv/repo/aos_test#{System.get_env("MIX_TEST_PARTITION")}_#{System.system_time(:millisecond)}.db"

encryption_keys =
  System.get_env("ENCRYPTION_KEYS") || "ho0ff2dh8SEt9GHj+7ottBz+Gam0En8UTq2eCCOCxpQ="

# This value is hardcoded for test.
secret_key_base = "LLRgjeeWvf1K1U0vsGVCESK4AcTD2lXnL1x13SLiac7XW4UhwW2PWaxE+ejIMeUs"

website_host = System.get_env("WEBSITE_HOST") || "localhost"

scheme = if website_host != "localhost", do: "https", else: "http"

# Configurations the app itself
config :aos,
  # No initial Admin Users in test.
  admin_users: "'[]'",
  api_key: "test-aos-api-key",
  api_rate_limit: {1_000, 60_000},
  base_url: "#{scheme}://#{website_host}:#{application_port}/",
  database_path: database_path,
  encryption_keys: encryption_keys,
  old_admin_users: "'[]'",
  llm_provider: AOS.AgentOS.LLM.Provider.Fake,
  scheme: scheme,
  sync_async_executions: true,
  website_host: website_host

# Configure the database
config :aos, AOS.Repo,
  database: database_path,
  busy_timeout: 5_000,
  pool: Ecto.Adapters.SQL.Sandbox,
  ssl: false

config :tzdata, :autoupdate, :disabled

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aos, AOSWeb.Endpoint,
  http: [port: application_port],
  live_view: [signing_salt: secret_key_base],
  secret_key_base: secret_key_base,
  server: false,
  url: [host: website_host, port: application_port]

# Print only warnings and errors during test
config :logger, level: :warning
