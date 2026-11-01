import Config

db_uri = System.get_env("DATABASE_URI")
if is_nil(db_uri) do
  raise "environment variable \"DATABASE_URI\" is missing."
end

config :ashiato, Ashiato.Repo,
  adapter: Ecto.Adapters.Postgres,
  url: db_uri,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1")

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :ashiato, AshiatoWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Configure Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Req

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
