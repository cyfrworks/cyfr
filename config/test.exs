# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# We don't run a server during test
# The establish memo is a per-request convenience; tests assert on the
# uncached pipeline.
config :cyfr, :establish_cache_ms, 0

config :cyfr, EmissaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-minimum-64-characters-long-for-testing-only",
  server: false

# The origin an absolute URL falls back to, the endpoint's own above.
config :sanctum, :fallback_origin, "http://localhost:4002"

# Effectively disable the MCP transport rate limit in tests — controller
# suites drive hundreds of /mcp requests from 127.0.0.1 within one window.
# MCPRateLimitTest overrides this per-test to exercise the limiter itself.
config :cyfr, :mcp_rate_limit_max, 1_000_000

# Proofs likewise: unit tests run on the ETS store; proof_db_test.exs
# exercises the durable adapter directly.
config :sanctum, :consent_proof_store, Sanctum.Consent.Proof.Memory

# Same for the tincture transport rate limit; TinctureRateLimitTest and the
# tincture controller's 429 tests override this per-test.
config :cyfr, :tincture_rate_limit_max, 1_000_000

# No network from tests: the registry health probe is a real DNS + TLS
# round-trip with a 3s timeout — pure wall clock and straggling sockets
# in a suite. Surfaces render its "unknown" answer.
config :cyfr, :registry_health_probe, false

# Both registry endpoints point at a closed loopback port: a registry is
# configured, so the "registry does not answer" paths run, and no test can
# reach a registry off this machine. `:registry_url` decides whether a
# registry is configured at all and where its REST API is; `:oci_registry_url`
# is what a pull resolves against. A test that needs the public host name
# sets it locally and asserts through `Compendium.RegistryHost.canonical_host/0`.
config :cyfr, :registry_url, "127.0.0.1:19"
config :cyfr, :oci_registry_url, "127.0.0.1:19"

# Configure Arca for tests (use sandboxed pool). The adapter is selected at
# build time in config.exs from CYFR_DATABASE; the per-adapter opts must
# match (SQLite-only keys break a Postgres connect, and Postgres needs a URL
# or hostname/credentials to authenticate).
#
# The sandbox funnels every process a test spawns through the one connection
# it owns, so a burst of concurrent tasks each writing an audit row queues on
# it. The production queue drop target (50 ms) is tuned for a real pool and
# would drop those requests under load; give the single shared connection room.
case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
  :sqlite ->
    # Stable across runs (so migrations are reused) and keyed by checkout
    # (so two worktrees never share a file) — but OUT of the repo's data/:
    # a run that dies mid-suite must not leave a database that poisons the
    # next one inside the working tree.
    config :cyfr, Arca.Repo,
      database:
        Path.join([
          System.tmp_dir!(),
          "cyfr_test_db_#{:erlang.phash2(Path.expand("."))}",
          "test.db"
        ]),
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000,
      queue_target: 500,
      queue_interval: 5_000,
      journal_mode: :wal,
      # Allow SQLite writers to wait for contention between concurrent test fixtures.
      busy_timeout: 20_000

  :postgres ->
    config :cyfr, Arca.Repo,
      url:
        System.get_env("CYFR_DATABASE_URL") ||
          "postgres://cyfr:cyfr@localhost:5432/cyfr_test",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000,
      queue_target: 500,
      queue_interval: 5_000
end

# Disable auto-migration in tests — mix aliases handle ecto.migrate
config :cyfr, auto_migrate: false

# The suite's fake servers (Bypass, a local registry) live on loopback; the
# operator's private-egress allowlist names them, as it would name a real
# internal host. Tests that exercise the refusal override this.
config :cyfr, private_egress_targets: ["localhost", "127.0.0.1/8", "::1"]

# Allow tests to inject a membership-resolution override (Sanctum.Tenancy).
# Compile-time gate: production releases compile this to false and never honor
# the override. See Sanctum.Tenancy "Test overrides".
config :cyfr, allow_tenancy_resolver_override: true

# One app's tests run without the sibling apps' providers; the catalog
# boots leniently here and refuses to elsewhere.
config :cyfr, tool_providers_lenient: true

# Don't run the background retention sweeper in the test supervision tree —
# its periodic DB cleanup conflicts with the Ecto sandbox connection lifecycle.
# Retention logic is exercised directly in Cyfr.RetentionTest / scheduler unit tests.
config :cyfr, retention_scheduler_enabled: false

# The reconciler reacts to vault broadcasts with DB reads from its own
# process, which races the shared sandbox connection; its own suite
# starts it explicitly.
config :cyfr, external_server_reconciler_enabled: false

# Start the cron scheduler only within its tests so its database work
# stays within the owning test's sandbox lifetime.
config :cyfr, cron_scheduler_enabled: false

# The boot task writes rows (the operator reconcile, the seed sync) before
# any test's sandbox checkout — both are exercised directly by their own
# tests.
config :cyfr, provisioning_boot_enabled: false

# Likewise the thread-runner boot recovery reads the repo before any
# sandbox exists; the runner suite drives recovery itself.
config :cyfr, thread_recovery: false

# Bookkeeping rows are written in the caller: the sandbox connection is the
# test's, and every assertion reads the row right after the call.
config :cyfr, record_sink_inline: true

# Same for the provisioning retries a sign-in kicks off.
config :cyfr, provisioning_inline: true

# The stale-execution sweeper has the same shape (permanent named GenServer
# querying on a 60s timer) and the same sandbox hazard; its own suite
# exercises sweep logic directly.
config :cyfr, execution_sweeper_enabled: false

# Same reason as the sweeper: the archive watch would answer an archive
# from its own process, on a sandbox connection its test does not own.
# `Sanctum.Tenancy.ArchiveTest` starts it for the cases that assert a
# cancel, where it is stopped with the test that owns the connection.
config :cyfr, execution_archive_watch_enabled: false

# The worker watch follows the sweeper's flag by default; off by name here,
# since it polls the worker services on a timer and writes the lapses it
# finds. Its own suite starts it with the endpoints it serves.
config :cyfr, worker_watch_enabled: false

# The control-plane claim is the same shape again (a permanent GenServer
# renewing a DB lease); `Cyfr.ControlPlane.Claim` is exercised directly.
config :cyfr, control_plane_claim_enabled: false

# The boot's database checks (schema fingerprint, tenant roster, keyring
# fingerprint) read and write server rows outside any sandbox; the suite
# verifies the schema before it starts and exercises each check directly.
config :cyfr, database_checks_enabled: false

# Default storage roots for tests (individual tests may override), two
# throwaway SIBLING roots — the topology dev and prod use ("two trees, two
# lifetimes", Arca.Storage): `base_path` holds all tenant storage, and the
# seed tree starts with an empty bundle so no test sees one it did not
# write. Leaving either at its config.exs default would make tests read or
# write the repo's own trees. test_helper.exs copies the shipped AQUA
# template into the throwaway seed tree — it is only ever read in place
# through the overlay. test_helper.exs removes both roots after the suite.
test_run = "cyfr_test_#{System.system_time(:millisecond)}"

config :cyfr,
  base_path: Path.join(System.tmp_dir!(), "#{test_run}_data"),
  seed_path: Path.join(System.tmp_dir!(), "#{test_run}_seed")

# Sanctum test configuration
config :cyfr,
  secret_key_base: "test_dev_key_base_min_64_chars_for_aes256_key_derivation_padding!",
  # Namespace populated on Context.local() / Context.fixture-shaped contexts.
  # Production contexts should never use this — they get namespace from
  # CredentialStore via the session-resolution path.
  default_test_namespace: "testns"

# The worker root every key CYFR issues derives from (`Cyfr.WorkerAuth`),
# fixed for the suite so the Opus worker service of a test boot holds the
# key CYFR derives for its id: `worker_key(root, "wrk_local")`, spelled
# here as the HMAC it is (`Cyfr.MacEnvelope.derive/4`: the label, then the
# service id, one per line) because the contracts are not compiled when
# this file is read. `Cyfr.ExecutionTest` pins the two spellings to each
# other.
test_worker_root = :crypto.hash(:sha256, "cyfr-test-worker-root")
config :cyfr, :worker_key, test_worker_root

# The Opus service of a test boot listens on a port of the system's choosing,
# and so does CYFR's host API listener; `Cyfr.Test.OpusService` points each
# at the other's once both are up. Its runners are OS processes of their
# own, started by the `Direct` keeper and pooled across tests; a runner
# holds no sys.config, so what it takes from this configuration (the log
# level, the scheduler counts) the service passes it explicitly
# (`Opus.Release.runner_command/0`).
config :opus,
  service_key:
    :hmac
    |> :crypto.mac(:sha256, test_worker_root, "cyfr-worker/v1/worker\nwrk_local")
    |> Base.encode16(case: :lower),
  port: 0,
  keeper: :direct

config :cyfr, :host_api_port, 0

# Print only warnings and errors during test
config :logger, level: :warning

# The namespace read is cached per person for a minute in production; a
# sandbox rollback is a write no invalidation ever sees, so tests read the
# users row every time.
config :cyfr, :namespace_cache_ttl_ms, 0

# A subscription stream is long-lived by design, so a test that opens one would
# otherwise block until the production bound. Short enough that the graceful
# close is what the assertions actually observe.
config :cyfr, :mcp_subscription_max_ms, 50
