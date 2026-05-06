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

# MCP tool providers - each service registers its tools
# Order doesn't matter, tools are indexed by name
config :cyfr,
  tool_providers: [
    # Foundation services
    Sanctum.MCP,
    Arca.MCP,
    # Domain services
    Opus.MCP,
    Opus.CronMCP,
    Locus.MCP,
    Compendium.MCP,
    # External MCP server management
    Emissary.MCP.ExternalProvider,
    # System/transport (cross-cutting)
    Emissary.MCP.Tools.SystemProvider
  ]

# Configures the endpoint
config :cyfr, EmissaryWeb.Endpoint,
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
  metadata: [:request_id, :user_id, :org_id, :project_id, :auth_method]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Redact sensitive values from inbound request logs.
# Note: this only masks inbound request params. Outbound response bodies must be
# redacted separately — see Compendium.Registry.Client token-redacting wrapper.
config :phoenix, :filter_parameters,
  ["password", "secret", "token", "push_token", "access_token", "client_secret"]

# Arca Repo adapter is selected at compile time. The `cyfr` release builds
# with SQLite (default). The `cyfr_arx` release sets CYFR_BUILD_FOR=arx
# at build time to switch to Postgres. The FOSS mirror has neither apps/arx/
# nor this env var set, so it always builds with SQLite. Adapter-specific
# Repo defaults are scoped accordingly so SQLite-only keys (journal_mode,
# busy_timeout) never bleed into the Postgres build's merged config.
if System.get_env("CYFR_BUILD_FOR") == "arx" do
  config :cyfr, :repo_adapter, Ecto.Adapters.Postgres
  # Postgres URL, pool, ssl are set in apps/arx/config/runtime.exs.
  config :cyfr, Arca.Repo, []
else
  config :cyfr, :repo_adapter, Ecto.Adapters.SQLite3

  config :cyfr, Arca.Repo,
    database: "data/cyfr.db",
    pool_size: 20,
    journal_mode: :wal,
    busy_timeout: 5_000
end

config :cyfr, ecto_repos: [Arca.Repo]

# Arca Storage Configuration
# Paths are expanded to absolute at config time so they don't depend on runtime CWD,
# which can vary across umbrella apps during startup.
config :cyfr,
  storage_adapter: Arca.Adapters.Local,
  base_path: Path.expand("./data"),
  components_path: Path.expand("./components"),
  aqua_path: Path.expand("./aqua")

# WIT path for component scaffolding and WASM builds
config :cyfr, :wit_path, Path.expand("../wit", __DIR__)

# Locus Build Service Configuration
config :locus,
  wit_path: Path.expand("../wit", __DIR__),
  compile_timeout_ms: 300_000

# CORS Configuration — wildcard default for Core, restricted for Arx
config :cyfr, :cors_allowed_origins, ["*"]

# Sanctum Configuration
# Auth provider is set in runtime.exs based on environment variables
config :cyfr, pubsub_name: Emissary.PubSub

# Edition-specific behaviour resolvers — Core defaults; Arx overrides via
# arx_runtime.exs (will move to apps/arx/config/runtime.exs in Phase 3).
# Callers do `Application.fetch_env!(:cyfr, :membership_resolver).resolve(user_id)`
# instead of probing for Arx modules with `Code.ensure_loaded?`.
config :cyfr,
  membership_resolver: Sanctum.NoopMembershipResolver,
  plan_resolver: Sanctum.NoopPlanResolver,
  tenant_policy: Sanctum.PermissiveTenantPolicy

# Audit sink configuration
# Core ships with Console sink. Arx can add SIEM/S3 sinks via arx_runtime.exs.
config :cyfr, :audit_sinks, [Arca.AuditSinks.Console]

# Prism Dashboard Endpoint
config :cyfr, PrismWeb.Endpoint,
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
    cd: Path.expand("../apps/cyfr/assets", __DIR__),
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
    cd: Path.expand("../apps/cyfr/assets", __DIR__)
  ]

# Ueberauth base configuration
# Provider strategies are configured in apps/arx for enterprise
config :ueberauth, Ueberauth,
  providers: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
