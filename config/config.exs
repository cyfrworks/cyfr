# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Register the SSE MIME type. This dependency configuration is compiled;
# run `mix deps.clean mime --build` after changing it.
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
    # Chat on the wire, so Prism is a client of the agent runtime rather
    # than the only way to reach it.
    Emissary.MCP.ConversationTool,
    # A card decided from the wire: the same door the console's buttons use.
    Emissary.MCP.ApprovalTool,
    # What was kept out of a conversation — a separate object from the tape,
    # which is what lets a thread be erased honestly.
    Emissary.MCP.NotesTool,
    # The athanor's files as the Files page shows them, one tier per folder.
    Emissary.MCP.FileTool,
    # A component's own source, for the agent authoring it — host-side and
    # scoped, because the files catalyst's grant is `data/` and widening it
    # would widen it for every agent.
    Compendium.MCP.SourceTool,
    # Domain services
    Opus.MCP,
    Cyfr.Schedules.Provider,
    Locus.MCP,
    Compendium.MCP,
    # External MCP server management. `Emissary.MCP.ExternalProvider` is not
    # here: it owns no tool of its own — the tools it discovers are the
    # upstream servers', reached through `Cyfr.Ops.Catalog` on a lookup miss.
    Emissary.MCP.McpServersTool,
    # System/transport (cross-cutting)
    Emissary.MCP.Tools.SystemProvider
  ]

# Consent proofs are durable: the plan → preview → commit walk spans human
# minutes and must survive a restart. Tests override to the ETS store.
config :cyfr, :consent_proof_store, Sanctum.Consent.Proof.DB

# Store consent revisions in the database; tests override this with the Memory adapter.
config :cyfr, :consent_source, Sanctum.Consent.Source.DB

# Configures the endpoint
# The one endpoint: the API, the MCP transport, tinctures, and the Prism
# LiveViews all answer on it — one origin, one cookie, one login.
config :cyfr, EmissaryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PrismWeb.ErrorHTML, json: EmissaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Emissary.PubSub,
  live_view: [signing_salt: "cyfrLVdev"]

# Include module metadata in Logger output for filtering by emitter.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module, :request_id, :user_id, :athanor_id, :auth_method, :execution_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure the execution implementation before endpoint startup; unavailable code reports no engine.
config :cyfr, :execution_impl, Opus

# The byte store behind retained execution payloads
# (`Arca.ExecutionPayloads.Store`): the athanor's own tree by default.
config :cyfr, :execution_payload_store, Arca.ExecutionPayloads.Store.Overlay

# Inbound request-param redaction (:filter_parameters) is set at boot by
# Cyfr.Application from Sanctum.Sanitizer.filter_parameters/0 — the one
# redaction vocabulary. It is not spelled here so it cannot drift from it.
# Outbound response bodies are redacted at their call sites with
# Sanctum.Sanitizer.sanitize/1.

# Arca Repo adapter is selected at build time — Ecto can't swap adapters at
# runtime. The one CYFR_DATABASE parse lives in database_choice.exs (shared
# with test.exs). Adapter-specific Repo defaults are scoped accordingly so
# SQLite-only keys (journal_mode, busy_timeout) never bleed into the Postgres
# build's merged config; Postgres URL/pool/ssl are set in config/runtime.exs.
Code.require_file("database_choice.exs", __DIR__)

case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
  :sqlite ->
    config :cyfr, :repo_adapter, Ecto.Adapters.SQLite3

    config :cyfr, Arca.Repo,
      database: Path.expand("data/cyfr.db"),
      pool_size: 20,
      journal_mode: :wal,
      busy_timeout: 5_000

  :postgres ->
    config :cyfr, :repo_adapter, Ecto.Adapters.Postgres
    config :cyfr, Arca.Repo, []
end

config :cyfr, ecto_repos: [Arca.Repo]

# Arca Storage Configuration
# Paths are expanded to absolute at config time so they don't depend on runtime CWD,
# which can vary across umbrella apps during startup. The seed tree (the
# component bundle and the AQUA agent template, `Arca.Storage.seed_roots/0`)
# is anchored to the repo, not the CWD: it is read wherever the app runs from.
# In dev and prod these are compile-time placeholders only — runtime.exs
# re-resolves both through Cyfr.RuntimeConfig.resolve_paths/1 (CWD-anchored
# defaults; run dev from the umbrella root). Test pins its own tmp roots.
config :cyfr,
  storage_adapter: Arca.Adapters.Local,
  base_path: Path.expand("./data"),
  seed_path: Path.expand("../seed", __DIR__)

# Map each overlaid root to its unit locator. Every overlay root requires
# a locator defining its unit boundaries.
config :cyfr, :overlay_locators, %{
  "aqua" => Compendium.AquaPath,
  "components" => Compendium.ComponentPath
}

# Recursive file and byte ceilings for public-profile guest writes.
# Authenticated tenant storage uses CYFR_ATHANOR_STORAGE_BYTES.
config :cyfr, :public_storage_quota, %{max_bytes: 26_214_400, max_files: 200}

# Concurrent object reads in the shared subtree dump
# (Arca.Storage.read_subtree_via/4) — bounded so a wide tree cannot open
# unbounded connections on the object-store path.
config :cyfr, :read_subtree_concurrency, 10

# Decompression ceiling for published tincture archives (zip-bomb guard).
config :cyfr, :tincture_max_decompressed_bytes, 256 * 1024 * 1024

# The shared-cache sweeper's budgets: raw binaries held (bytes) and
# compiled components pinned (count) — how much a node may hold in the one
# ETS table (`Arca.Cache.Sweeper`).
config :cyfr, :cache_max_binary_bytes, 256 * 1024 * 1024
config :cyfr, :cache_max_compiled_components, 32

# External MCP server connections per athanor, and concurrent in-flight
# calls one server process admits before refusing (`Emissary.MCP`).
config :cyfr, :max_external_servers, 50
config :cyfr, :external_server_max_in_flight, 8

# How long a dispensed OAuth token stays tracked for output masking
# (`Opus.OAuthTokenTracker`), how long a returning sign-in waits on the
# cyfr.run probe before proceeding without it (`Sanctum.SignIn`), and the
# retention sweep interval (`Cyfr.RetentionScheduler`).
config :cyfr, :oauth_token_ttl_ms, :timer.hours(1)

# The deadline, in milliseconds, for one provisioning attempt's required
# dependency pulls: the closure of every component the bundle cannot run
# without, pulled when an athanor is first filled and at the seed sync
# after a release. A pull past it stops where it is; what landed stays
# registered, the estate is left unprovisioned with the timeout recorded,
# and the next attempt resumes from what is installed. The OCI transport
# waits up to two minutes per request and retries twice, so one stalled
# blob can hold an attempt for several minutes within this bound.
config :cyfr, :provisioning_required_pull_budget_ms, :timer.minutes(10)
config :cyfr, :returning_probe_ms, 5_000
# The context window assumed for a model whose catalyst reports none and
# whose catalyst name the host's table does not know, in tokens. The loop
# compacts a conversation against this when nothing better is reported.
config :cyfr, :model_context_window_default, 128_000

config :cyfr, :retention_scheduler_interval, :timer.hours(6)

# How long an approval card waits for a decision before it expires as a
# denial the agent observes, in hours. An estate overrides it in its
# settings under `approvals.expiry_hours`.
config :cyfr, Aqua.Approvals, expiry_hours: 24

# Default retention windows used by Cyfr.Retention sweeps.
config :cyfr, Cyfr.Retention,
  # Newest N executions kept per athanor.
  executions: 10_000,
  # Days an execution record is kept, whatever the count.
  execution_days: 90,
  # Days a retained execution payload is kept, per retention class: the
  # default class and chat steps, webhook-driven runs, scheduled runs and
  # the server's own runs.
  payload_days: 30,
  webhook_payload_days: 14,
  schedule_payload_days: 30,
  system_payload_days: 7,
  # Newest N build records kept per athanor.
  builds: 100,
  # Days of policy-enforcement log kept.
  policy_log_days: 30,
  # Days of MCP request log kept.
  mcp_log_days: 30,
  # Days of conversation messages kept.
  messages_days: 365

# Read-but-not-set here, deliberately: `:webhook_max_body_bytes` derives
# its default from `Sanctum.Limits.default_max_request_size/0` (a literal
# here would be a second spelling of a derived value), and
# `:platform_ceiling` is a structured policy override
# (`Sanctum.Policy.Ceiling`), not a scalar knob.

# CORS Configuration — wildcard default for fresh installs. The boot guard in
# Cyfr.Application requires an explicit allowlist once authentication is
# configured. Override via CYFR_CORS_ALLOWED_ORIGINS.
config :cyfr, :cors_allowed_origins, ["*"]

# Prometheus metrics — off by default because the /metrics endpoint is
# unauthenticated. Opt in via CYFR_PROMETHEUS_METRICS=true (dev.exs enables it
# for local development).
config :cyfr, :prometheus_metrics_enabled, false

# Sanctum Configuration
# Auth provider is set in runtime.exs based on environment variables

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
