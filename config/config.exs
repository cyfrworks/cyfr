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
    # the immediate mode is also the one a transaction opened with no mode
    # takes. The database file, the pool and the journal mode are
    # `config/runtime.exs`'s.
    config :arca, Arca.Repo,
      busy_timeout: 5_000,
      default_transaction_mode: :immediate

  :postgres ->
    config :arca, :repo_adapter, Ecto.Adapters.Postgres
end

config :arca, ecto_repos: [Arca.Repo]

# Tenant storage on the local filesystem. Its roots, `:base_path` and
# `:seed_path`, are `config/runtime.exs`'s
# (`Cyfr.RuntimeConfig.resolve_paths/1`) and `config/test.exs`'s.
config :arca, storage_adapter: Arca.Adapters.Local

# Recursive file and byte ceilings for public-profile guest writes.
# Authenticated tenant storage uses CYFR_ATHANOR_STORAGE_BYTES.
config :cyfr, :public_storage_quota, %{max_bytes: 26_214_400, max_files: 200}

# The deadline, in milliseconds, for one provisioning attempt's required
# dependency pulls: the closure of every component the bundle cannot run
# without, pulled when an athanor is first filled and at the seed sync
# after a release. A pull past it stops where it is; what landed stays
# registered, the athanor is left unprovisioned with the timeout recorded,
# and the next attempt resumes from what is installed. The OCI transport
# waits up to two minutes per request and retries twice, so one stalled
# blob can hold an attempt for several minutes within this bound.
config :cyfr, :provisioning_required_pull_budget_ms, :timer.minutes(10)

# CORS allowlist: empty, no cross-origin browser caller, which a
# same-origin deployment needs. `config/runtime.exs` writes
# CYFR_CORS_ALLOWED_ORIGINS's list over it. The boot guard in
# Cyfr.Application refuses a wildcard once authentication is configured.
config :cyfr, :cors_allowed_origins, []

# Prometheus metrics: off, because the /metrics endpoint is
# unauthenticated; CYFR_PROMETHEUS_METRICS=on turns them on (dev.exs turns
# them on for local development).
config :cyfr, :prometheus_metrics_enabled, false

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

# Prism tailwind configuration. A version bump adds the CLI's sha256 pins
# for it to scripts/fetch-prebuilt-binaries.sh, which lays the CLI down and
# refuses a version it holds no pin for.
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
