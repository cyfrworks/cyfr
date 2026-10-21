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
config :sanctum,
  tool_providers: [
    # Each provider answers its namespace's service label (`service/0`),
    # and a namespace with several providers is one service. Identity and
    # authority, `sanctum`:
    Sanctum.Provider,
    # `sanctum`: the decision record, the request log and the policy log,
    # security rows read under the caller's actor alone.
    Sanctum.Providers.Decision,
    Sanctum.Providers.McpLog,
    Sanctum.Providers.PolicyLog,
    # `arca`: the execution records the storage layer keeps and its
    # retention policy, handed the caller's actor alone.
    Arca.Providers.Records,
    # `aqua`: chat on the wire, so Prism is a client of the agent runtime
    # rather than the only way to reach it.
    Aqua.Providers.Thread,
    # A card decided from the wire: the same door the console's buttons use.
    Aqua.Providers.Approval,
    # What was kept out of a thread — a separate object from the tape,
    # which is what lets a thread be erased honestly.
    Aqua.Providers.Notes,
    # `arca`: the athanor's files as the Files page shows them, one tier
    # per folder.
    Arca.Providers.Files,
    # `compendium`: a component's own source, for the agent authoring it —
    # host-side and scoped, because the files catalyst's grant is `data/`
    # and widening it would widen it for every agent.
    Compendium.Providers.Source,
    # `opus`: executions, schedules and a tincture's invocations.
    Opus.Provider,
    Opus.Schedules.Provider,
    # `opus`: an athanor's feeds, and the streams a canvas reads.
    Opus.Providers.Feed,
    Opus.Providers.Tincture,
    # `compendium`: builds and components.
    Compendium.Builds.Provider,
    Compendium.Provider,
    # `compendium`: a person's layout document, which Prism reads to place
    # the canvases. Its `edit` is the layout's one publisher, called for the
    # person by the CLI, the API, a paired glass or an agent whose policy
    # and grant name it; no Prism page calls it.
    Compendium.Providers.Layout,
    # `compendium`: a person's canvases, their versions and what a canvas
    # may read, beside the declaration a canvas version is held to.
    Compendium.Providers.Canvas,
    # `emissary`: external MCP server management. `Emissary.External.Proxy`
    # is not here: it owns no tool of its own — the tools it discovers are
    # the upstream servers', reached through `Sanctum.Catalog` on a lookup
    # miss.
    Emissary.External.Provider,
    # `sanctum`: the gate's own `system` tool.
    Sanctum.Providers.System,
    # `cyfr`: the platform settings, for the server's operators.
    Cyfr.Providers.Settings
  ]

# Consent proofs are durable: the plan → preview → commit walk spans human
# minutes and must survive a restart. Tests override to the ETS store.
config :sanctum, :consent_proof_store, Sanctum.Consent.Proof.DB

# How long a read of a caller's credential and standing is trusted: the
# establish memo's TTL and the age past which a retained context is
# revalidated before it is acted on (`Sanctum.Caller.fresh?/1`). A security
# bound, not a tuning knob — it is how long a revocation no announcement
# reached can go unread anywhere in the cell.
config :sanctum, :caller_memo_ttl_ms, 2_000

# The boot check of stored grants (`Sanctum.Consent.StoredGrants`): every
# member's boot logs the grants that name a storage path the grammar no
# longer admits, and the cell announces them to their athanors once per
# cell, only when the list changes. A notice; the loader refuses such a
# grant whether or not it runs. The suite turns it off.
config :sanctum, :stored_grants_check_enabled, true

# Where this deployment is reachable when it has no public URL: a local
# home's address, `http://localhost:<port>`, kept in step with the
# endpoint below and with the per-environment ports, which override this
# value. `config/runtime.exs` writes it, and `:sanctum, :public_url`, from
# the home's access settings (`Cyfr.RuntimeConfig.resolve_access/1`); an OAuth
# `redirect_uri` needs an absolute origin either way.
config :sanctum, :fallback_origin, "http://localhost:4000"

# The proxies whose forwarded headers the proxy listener trusts
# (`Sanctum.ClientIp`): none, as a local home has no proxy listener.
# `config/runtime.exs` writes the access settings'.
config :sanctum, :proxy_trust, :none

# Whose HSTS a response carries (`CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts/1`):
# none, a local home's. `config/runtime.exs` writes the access settings': the
# endpoint's on the proxy listener in a tailnet home, Caddy's in a public
# one.
config :cyfr, :hsts, :none

# Configures the endpoint
# The one endpoint: the API, the MCP transport, tinctures, and the Prism
# LiveViews all answer on it — one origin, one cookie, one login — on its
# loopback listener (`http:`) and, in a tailnet or public home, the proxy
# listener (`proxy:`), each started and tagged by `CyfrWeb.Ingress`.
config :cyfr, CyfrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: CyfrWeb.Ingress,
  render_errors: [
    formats: [html: PrismWeb.ErrorHTML, json: CyfrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cyfr.PubSub,
  live_view: [signing_salt: "cyfrLVdev"],
  # The drain, in every environment: on shutdown each listener stops
  # accepting and lets the connections already open finish for this long
  # before it closes them. Each environment's `http:` merges over it, and
  # the proxy listener takes every option here but the address and port.
  http: [
    thousand_island_options: [shutdown_timeout: 30_000],
    # HTTP/1.1 alone, in every environment, as the release's `http:` in
    # config/runtime.exs says too, so dev and test serve what the release
    # serves. A WebSocket upgrades from HTTP/1.1 and SSE streams as an
    # HTTP/1.1 response, so neither needs HTTP/2.
    http_2_options: [enabled: false]
  ]

# Include module metadata in Logger output for filtering by emitter.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module, :request_id, :user_id, :athanor_id, :auth_method, :execution_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The worker services runs are dispatched to (`Opus.Dispatch`):
# each entry is a `Prima.WorkerAPI.endpoint/0` — the worker service's
# configured id (the id `Prima.WorkerAuth` derives its keys over), the base
# URL of its listener (`Prima.WorkerWire`) and the components it alone runs
# (nil for any). A run goes to the first entry whose status answers its id,
# over `Opus.WorkerClient`. With none, a run is refused as
# :execution_unavailable. The runtime configuration replaces this list with
# `CYFR_LOCUS_RUNTIME_WORKERS`; the default names the runtime of a local boot.
config :cyfr, :locus_runtime_workers, [
  %{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}
]

# The runtime role's worker service: its own id, which every assignment it
# accepts must name, where it reaches CYFR's host API, and where its
# listener binds (the `wrk_local` entry above). Its service key is the
# worker key CYFR derives for that id (`Prima.WorkerAuth.worker_key/2`,
# 64 hex): the test configuration derives it from the test runtime root,
# a development boot derives it from its root in `config/runtime.exs`, and
# the `locus` release receives it from `LOCUS_RUNTIME_KEY`
# (`config/locus_runtime.exs`). A node serves the runtime only once it
# holds that key.
config :locus, :runtime,
  service_id: "wrk_local",
  host_url: "http://127.0.0.1:4300",
  bind: "127.0.0.1",
  port: 4200

# The byte store behind retained execution payloads
# (`Arca.ExecutionPayloads.Store`): the athanor's own tree by default.
config :arca, :execution_payload_store, Arca.ExecutionPayloads.Store.Overlay

# Inbound request-param redaction (:filter_parameters) is set at boot by
# Cyfr.Application from Prima.Sanitizer.filter_parameters/0 — the one
# redaction vocabulary. It is not spelled here so it cannot drift from it.
# Outbound response bodies are redacted at their call sites with
# Prima.Sanitizer.sanitize/1.

# Arca Repo adapter is selected at build time — Ecto can't swap adapters at
# runtime. The one CYFR_DATABASE parse lives in database_choice.exs (shared
# with test.exs). Adapter-specific Repo defaults are scoped accordingly so
# SQLite-only keys (journal_mode, busy_timeout) never bleed into the Postgres
# build's merged config; Postgres URL/pool/ssl are set in config/runtime.exs.
Code.require_file("database_choice.exs", __DIR__)

case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
  :sqlite ->
    config :arca, :repo_adapter, Ecto.Adapters.SQLite3

    # Every transaction takes the write lock at its start. A transaction that
    # reads and then takes the lock fails with SQLITE_BUSY_SNAPSHOT when
    # another write committed in between, which would surface as a lost
    # write. `Arca.Repo.prepare_transaction/2` takes it for every transaction
    # the repo opens, waiting at most `busy_timeout` (the lock-wait deadline);
    # the immediate default is kept for a transaction opened with no mode,
    # of which the tree has none today (the sandbox passes its own).
    config :arca, Arca.Repo,
      database: Path.expand("data/cyfr.db"),
      pool_size: 20,
      journal_mode: :wal,
      busy_timeout: 5_000,
      default_transaction_mode: :immediate

  :postgres ->
    config :arca, :repo_adapter, Ecto.Adapters.Postgres
    config :arca, Arca.Repo, []
end

config :arca, ecto_repos: [Arca.Repo]

# Arca Storage Configuration
# Paths are expanded to absolute at config time so they don't depend on runtime CWD,
# which can vary across umbrella apps during startup. The seed tree (the
# component bundle and the AQUA agent template, `Arca.Storage.seed_roots/0`)
# is anchored to the repo, not the CWD: it is read wherever the app runs from.
# In dev and prod these are compile-time placeholders only — runtime.exs
# re-resolves both through Cyfr.RuntimeConfig.resolve_paths/1 (CWD-anchored
# defaults; run dev from the umbrella root). Test pins its own tmp roots.
config :arca,
  storage_adapter: Arca.Adapters.Local,
  base_path: Path.expand("./data"),
  seed_path: Path.expand("../seed", __DIR__)

# Recursive file and byte ceilings for public-profile guest writes.
# Authenticated tenant storage uses CYFR_ATHANOR_STORAGE_BYTES.
config :cyfr, :public_storage_quota, %{max_bytes: 26_214_400, max_files: 200}

# Concurrent object reads in the shared subtree dump
# (Arca.Storage.read_subtree_via/4) — bounded so a wide tree cannot open
# unbounded connections on the object-store path.
config :arca, :read_subtree_concurrency, 10

# Decompression ceiling for published tincture archives (zip-bomb guard).
config :cyfr, :tincture_max_decompressed_bytes, 256 * 1024 * 1024

# The shared-cache sweeper's budgets: raw binaries held (bytes) and
# compiled components pinned (count) — how much a node may hold in the one
# ETS table (`Arca.Cache.Sweeper`).
config :arca, :cache_max_binary_bytes, 256 * 1024 * 1024
config :arca, :cache_max_compiled_components, 32

# Concurrent in-flight calls one external MCP server process admits before
# refusing (`Emissary.MCP`), and the backends one stdio server may define
# (`Emissary.External.BackendDefinition`).
config :cyfr, :external_server_max_in_flight, 8
config :cyfr, :max_backends_per_server, 4

# The deadline, in milliseconds, for one provisioning attempt's required
# dependency pulls: the closure of every component the bundle cannot run
# without, pulled when an athanor is first filled and at the seed sync
# after a release. A pull past it stops where it is; what landed stays
# registered, the athanor is left unprovisioned with the timeout recorded,
# and the next attempt resumes from what is installed. The OCI transport
# waits up to two minutes per request and retries twice, so one stalled
# blob can hold an attempt for several minutes within this bound.
config :cyfr, :provisioning_required_pull_budget_ms, :timer.minutes(10)

# How long a returning sign-in waits on the cyfr.run probe before
# proceeding without it (`Sanctum.SignIn`), in milliseconds.
config :cyfr, :returning_probe_ms, 5_000

# The reconciler of the component registry and the agent index
# (`Compendium.ProjectionReconciler`): whether it runs, how often it
# recovers every athanor a seeded root is behind in while this member holds
# its slot, and how old a pending change must be before its writer is
# taken for gone — given one repair attempt, then settled where it stands.
config :cyfr, Compendium.ProjectionReconciler,
  enabled: true,
  interval_ms: :timer.minutes(1),
  settle_after_ms: :timer.seconds(60)

# How long an approval card waits for a decision before it expires as a
# denial the agent observes, in hours. An athanor overrides it in its
# settings under `approvals.expiry_hours`.
config :cyfr, Aqua.Approvals, expiry_hours: 24

# Default retention windows, per kind (`Arca.Retention.Kind`); an athanor's
# own settings override each. Every kind carries the same default in code.
config :arca, Arca.Retention,
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
  # Days an athanor keeps its admission decisions. The decisions made
  # before any tenant was resolved are the host's, kept for
  # CYFR_DECISION_RETENTION_DAYS (`Cyfr.RetentionScheduler`).
  decisions_days: 90,
  # Days of thread messages kept.
  messages_days: 365,
  # Days a settled storage write intent is kept — the evidence of what
  # became of one guest write. A guest reads it back within a turn or two
  # of an uncertain write, so it is kept as long as a retained payload and
  # not as long as the execution row it hangs from.
  write_intent_days: 30,
  # Days a staged unit revision no pointer or draft keeps is left
  # before the storage sweep collects it (`Arca.StorageGC`). One day is
  # longer than any commit and short enough that a writer that died does
  # not hold its bytes against the athanor's cap for a week.
  staging_days: 1,
  # Days the deletion evidence of a seeded unit is kept once the
  # projection of its root has consumed it
  # (`Arca.StorageProjectionChanges`). A pending tombstone is kept
  # whatever its age.
  projection_tombstone_days: 7,
  # How many staged prefixes one sweep of one athanor collects or
  # repairs. A bound, not a target: the next sweep takes up where this one
  # stopped, so a large backlog is worked off over several runs rather
  # than in one long walk of the athanor's staging area.
  staging_sweep_limit: 200

# Read-but-not-set here, deliberately: `:webhook_max_body_bytes` derives
# its default from `Prima.Limits.default_max_request_size/0` (a literal
# here would be a second spelling of a derived value), and
# `:platform_ceiling` is a structured policy override
# (`Sanctum.Policy.Ceiling`), not a scalar knob.

# CORS allowlist: empty, no cross-origin browser caller, which a
# same-origin deployment needs. `config/runtime.exs` writes
# CYFR_CORS_ALLOWED_ORIGINS's list over it. The boot guard in
# Cyfr.Application refuses a wildcard once authentication is configured.
config :cyfr, :cors_allowed_origins, []

# Prometheus metrics: off, because the /metrics endpoint is
# unauthenticated; CYFR_PROMETHEUS_METRICS=on turns them on (dev.exs turns
# them on for local development).
config :cyfr, :prometheus_metrics_enabled, false

# Sanctum Configuration
# Auth provider is set in runtime.exs based on environment variables

# Prism esbuild configuration
config :esbuild,
  version: "0.28.2",
  prism: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/cyfr/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  # The tincture SDK: one self-contained script, injected into a tincture's
  # entry page and served at /sdk/cyfr.js. `mix esbuild sdk` rebuilds it;
  # the built file is tracked, since the entry page embeds it at compile
  # time.
  sdk: [
    args:
      ~w(js/sdk/index.js --bundle --format=iife --target=es2017 --outfile=../priv/static/sdk/cyfr.js) ++
        [
          "--banner:js=// SPDX-License-Identifier: Apache-2.0\n// Copyright 2026 CYFR Works Inc.\n// Built from apps/cyfr/assets/js/sdk by `mix esbuild sdk`."
        ],
    cd: Path.expand("../apps/cyfr/assets", __DIR__)
  ],
  # The canvas toolkit: two self-contained scripts built for a canvas's host
  # page to embed, the host bundle as its script and the worker bundle as
  # inert data the host starts its two workers from. `mix esbuild
  # toolkit_host` and `mix esbuild toolkit_worker` rebuild them; the built
  # files are tracked, and no `.gz` is built.
  toolkit_host: [
    args:
      ~w(js/toolkit/host.js --bundle --format=iife --target=es2020 --outfile=../priv/static/toolkit/host.js) ++
        [
          "--banner:js=// SPDX-License-Identifier: Apache-2.0\n// Copyright 2026 CYFR Works Inc.\n// Built from apps/cyfr/assets/js/toolkit by `mix esbuild toolkit_host`."
        ],
    cd: Path.expand("../apps/cyfr/assets", __DIR__)
  ],
  toolkit_worker: [
    args:
      ~w(js/toolkit/worker.js --bundle --format=iife --target=es2020 --outfile=../priv/static/toolkit/worker.js) ++
        [
          "--banner:js=// SPDX-License-Identifier: Apache-2.0\n// Copyright 2026 CYFR Works Inc.\n// Built from apps/cyfr/assets/js/toolkit by `mix esbuild toolkit_worker`."
        ],
    cd: Path.expand("../apps/cyfr/assets", __DIR__)
  ]

# Prism tailwind configuration
config :tailwind,
  version: "4.3.3",
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
