# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Register SSE MIME type for MCP server-sent events
config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

config :emissary,
  generators: [timestamp_type: :utc_datetime],
  # MCP tool providers - each service registers its tools
  # Order doesn't matter, tools are indexed by name
  tool_providers: [
    # Foundation services
    Sanctum.MCP,
    Arca.MCP,
    # Domain services
    Opus.MCP,
    Locus.MCP,
    Compendium.MCP,
    # System/transport (cross-cutting)
    Emissary.MCP.Tools.SystemProvider
  ]

# Configures the endpoint
config :emissary, EmissaryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: EmissaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Emissary.PubSub

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Arca Repo Configuration (SQLite)
config :arca, Arca.Repo,
  database: "data/cyfr.db",
  pool_size: 5

config :arca, ecto_repos: [Arca.Repo]

# Arca Storage Configuration
config :arca,
  storage_adapter: Arca.Adapters.Local,
  base_path: "./data",
  components_path: "./components"

# Sanctum Configuration
# Auth provider is set in runtime.exs based on environment variables
config :sanctum, []

# Prism Dashboard Endpoint
config :prism, PrismWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PrismWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Emissary.PubSub,
  live_view: [signing_salt: "Pr1smLV0"]

# Prism esbuild configuration
config :esbuild,
  version: "0.25.0",
  prism: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/prism/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Prism tailwind configuration
config :tailwind,
  version: "4.1.12",
  prism: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/prism/assets", __DIR__)
  ]

# Ueberauth base configuration
# Provider strategies are configured in sanctum_arx for enterprise
config :ueberauth, Ueberauth,
  providers: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
