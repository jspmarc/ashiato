# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# NOTE: Might be an issue when we need 8 bytes int, but for a small app, 4 bytes should suffice
config :ashiato, Ashiato.Repo, migration_primary_key: [type: :serial]

config :ashiato, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  repo: Ashiato.Repo

config :ashiato,
  ecto_repos: [Ashiato.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :ashiato, AshiatoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AshiatoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ashiato.PubSub,
  live_view: [signing_salt: "3hZ9C6Wu"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ashiato, Ashiato.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
