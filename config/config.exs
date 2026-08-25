# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
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
    Emissary.MCP.Tools.RecordsProvider,
    # Domain services
    Opus.MCP,
    Opus.CronMCP,
    Locus.MCP,
    Compendium.MCP,
    # External MCP server management. `Emissary.MCP.ExternalProvider` is not
    # here: it owns no tool of its own — the tools it discovers are the
    # upstream servers', reached through `ToolRegistry.try_handle/3`.
    Emissary.MCP.McpServersTool,
    # System/transport (cross-cutting)
    Emissary.MCP.Tools.SystemProvider
  ]

# Consent proofs are durable: the plan â preview â commit walk spans human
# minutes and must survive a restart. Tests override to the ETS store.
config :cyfr, :consent_proof_store, Sanctum.Consent.Proof.DB

# Consents themselves live in the database. Pinned here beside the proof
# store rather than left to an inline default: two halves of one seam, and
# only one of them was declared. Tests override to the Memory adapter.
config :cyfr, :consent_source, Sanctum.Consent.Source.DB

# Configures the endpoint
# The one endpoint: the API, the MCP transport, tinctures, and the Prism
# LiveViews all answer on it â one origin, one cookie, one login.
config :cyfr, EmissaryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PrismWeb.ErrorHTML, json: EmissaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Emissary.PubSub,
  live_view: [signing_salt: "cyfrLVdev"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :athanor_id, :auth_method]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Redact sensitive values from inbound request logs.
# Note: this only masks inbound request params. Outbound response bodies must be
# redacted separately â see Compendium.Registry.Client token-redacting wrapper.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "push_token",
  "access_token",
  "client_secret"
]

# Arca Repo adapter is selected at build time â Ecto can't swap adapters at
# runtime. Default is SQLite; set CYFR_DATABASE=postgres to build for
# Postgres. Adapter-specific Repo defaults are scoped accordingly so
# SQLite-only keys (journal_mode, busy_timeout) never bleed into the Postgres
# build's merged config; Postgres URL/pool/ssl are set in config/runtime.exs.
case String.downcase(System.get_env("CYFR_DATABASE", "sqlite")) do
  "sqlite" ->
    config :cyfr, :repo_adapter, Ecto.Adapters.SQLite3

    config :cyfr, Arca.Repo,
      database: Path.expand("data/cyfr.db"),
      pool_size: 20,
      journal_mode: :wal,
      busy_timeout: 5_000

  "postgres" ->
    config :cyfr, :repo_adapter, Ecto.Adapters.Postgres
    config :cyfr, Arca.Repo, []

  other ->
    raise "Unknown CYFR_DATABASE=#{other}; expected \"sqlite\" or \"postgres\""
end

config :cyfr, ecto_repos: [Arca.Repo]

# Arca Storage Configuration
# Paths are expanded to absolute at config time so they don't depend on runtime CWD,
# which can vary across umbrella apps during startup. The seed tree (the
# component bundle and the AQUA agent template, `Arca.Storage.seed_roots/0`)
# is anchored to the repo, not the CWD: it is read wherever the app runs from.
config :cyfr,
  storage_adapter: Arca.Adapters.Local,
  base_path: Path.expand("./data"),
  seed_path: Path.expand("../seed", __DIR__)

# Storage-adjacent knobs, spelled out so the defaults are discoverable —
# the readers fall back to the same values, but an invisible knob is a knob
# nobody knows to turn.
#
# The recursive file/byte ceiling for unauthenticated (public tincture)
# guest writes (`Opus.StorageHandler`); the operator's per-athanor cap for
# authenticated writes is CYFR_ATHANOR_STORAGE_BYTES.
config :cyfr, :public_storage_quota, %{max_bytes: 26_214_400, max_files: 200}

# Concurrent object reads in the S3 adapter's subtree dump (seeding,
# packing) — bounded so a wide tree cannot open unbounded connections.
config :cyfr, :s3_read_subtree_concurrency, 10

# Decompression ceiling for published tincture archives (zip-bomb guard).
config :cyfr, :tincture_max_decompressed_bytes, 256 * 1024 * 1024

# CORS Configuration â wildcard default for fresh installs. The boot guard in
# Cyfr.Application requires an explicit allowlist once authentication is
# configured. Override via CYFR_CORS_ALLOWED_ORIGINS.
config :cyfr, :cors_allowed_origins, ["*"]

# Prometheus metrics â off by default because the /metrics endpoint is
# unauthenticated. Opt in via CYFR_PROMETHEUS_METRICS=true (dev.exs enables it
# for local development).
config :cyfr, :prometheus_metrics_enabled, false

# Sanctum Configuration
# Auth provider is set in runtime.exs based on environment variables
config :cyfr, pubsub_name: Emissary.PubSub

# Audit sink configuration. Ships with the Console sink; a deployment can add
# SIEM/object-store sinks via release runtime config.
config :cyfr, :audit_sinks, [Arca.AuditSinks.Console]

# Prism esbuild configuration
config :esbuild,
  version: "0.25.0",
  prism: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
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
# Provider strategies are configured at runtime based on environment.
config :ueberauth, Ueberauth, providers: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
