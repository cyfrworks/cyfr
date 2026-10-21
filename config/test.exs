# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# The caller bound is off: the establish memo keeps nothing, so tests
# assert on the uncached pipeline, and every retained context is
# revalidated before each action it is used for.
config :sanctum, :caller_memo_ttl_ms, 0

# The suite runs no server.
config :cyfr, CyfrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-minimum-64-characters-long-for-testing-only",
  server: false

# The transports' retry backoff base and one directory request's bound,
# compiled in (`Compendium.Transport.Retry`, `Sanctum.Directory.Client`):
# shortened so a test of a retry or an unanswered request does not wait
# out a production delay. Every answered read in the suite (a fresh TLS
# connection to the scripted directory) runs under the same bound, so it
# stays well above what one takes on a loaded runner.
config :cyfr, transport_retry_base_ms: 5
config :sanctum, directory_request_ms: 5_000

# The decision log's database budget (`Arca.DecisionLog`), compiled in. On
# PostgreSQL its writer is bounded by the pool's timeout, and the pool
# closes a connection held past it; a sync test's shared sandbox is that
# test's only connection, so one audit write a loaded runner keeps past
# the production 500 ms would end the test's database mid-test. The
# budget's own tests read `Arca.DecisionLog.budget_ms/0`.
config :arca, decision_log_budget_ms: 5_000

# The origin an absolute URL falls back to, the endpoint's own above.
config :sanctum, :fallback_origin, "http://localhost:4002"

# The MCP Origin allowlist of a local home on the loopback, which
# `config/runtime.exs` resolves from the access settings for every other
# boot, with no extras.
config :cyfr,
  mcp_allowed_origins: [
    "http://localhost",
    "https://localhost",
    "http://127.0.0.1",
    "https://127.0.0.1",
    "http://[::1]",
    "https://[::1]"
  ],
  mcp_extra_origins: []

# The storage reserve's size, as `config/runtime.exs` sets it for a boot
# that names none (`Cyfr.RuntimeConfig.resolve_storage_reserve/1`); the
# suite keeps no reserve directory.
config :cyfr, :storage_reserve_bytes, 64 * 1024 * 1024

# A one-time confirmation code's transport: the tree ships none, so the
# suite captures each code where the test that asked for it reads it
# (`Sanctum.TestContext.MailSink`); a home without one refuses the email
# method (`Sanctum.Auth.EmailVerification`).
config :sanctum, :confirmation_code_transport, Sanctum.TestContext.MailSink

# The consent proof store: the suite's is the ETS store, and
# proof_db_test.exs exercises the durable adapter directly.
config :sanctum, :consent_proof_store, Sanctum.Consent.Proof.Memory

# The tincture transport rate limit, high enough that no suite trips it;
# TinctureRateLimitTest and the tincture controller's 429 tests override
# it per test.
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

# The runner supplies one private root per checkout/run/partition. Direct
# Mix invocations also get collision-resistant disposable roots; timestamps
# alone collide when multiple VMs evaluate config in the same millisecond.
test_partition = System.get_env("MIX_TEST_PARTITION", "0")

test_run_root =
  System.get_env("CYFR_TEST_RUN_ROOT") ||
    Path.join(
      System.tmp_dir!(),
      "cyfr_test_#{:erlang.phash2(Path.expand("."))}_#{System.pid()}_" <>
        "#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}_p#{test_partition}"
    )

# Mix's failures record (what `--failed` reruns), one path for every app
# of a VM rather than the build path of whichever app ran first: under the
# runner each partition's own file in its run root, and for a direct Mix
# run the build's canonical file.
umbrella_root = Path.expand("..", __DIR__)

config :ex_unit,
  failures_manifest_path:
    if(System.get_env("CYFR_TEST_RUN_ROOT"),
      do: Path.join(test_run_root, "failures"),
      else:
        Path.join(
          Path.expand(System.get_env("MIX_BUILD_PATH") || "_build/test", umbrella_root),
          "test_failures"
        )
    )

# Arca for tests, on the sandboxed pool. The adapter is the build's
# (`config/database_choice.exs` reads CYFR_DATABASE); the per-adapter opts
# must match (SQLite-only keys break a Postgres connect, and Postgres needs
# a URL or hostname/credentials to authenticate).
#
# The sandbox funnels every process a test spawns through the one connection
# it owns, so a burst of concurrent tasks each writing an audit row queues on
# it. The production queue drop target (50 ms) is tuned for a real pool and
# would drop those requests under load; give the single shared connection room.
case Cyfr.ConfigEnv.DatabaseChoice.choice!() do
  :sqlite ->
    config :arca, Arca.Repo,
      database: Path.join(test_run_root, "test.db"),
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000,
      queue_target: 500,
      queue_interval: 5_000,
      journal_mode: :wal,
      # Long enough for writers to wait out contention between concurrent
      # test fixtures, and below DBConnection's 15 s client timeout: a
      # statement still waiting inside the driver when the client gives up
      # has its connection closed under it, which crashes the VM.
      busy_timeout: 10_000

  :postgres ->
    # A partitioned run that names no URL still gets one database per
    # partition; `scripts/test-partitioned.sh` names them explicitly.
    config :arca, Arca.Repo,
      url:
        System.get_env("CYFR_DATABASE_URL") ||
          "postgres://cyfr:cyfr@localhost:5432/cyfr_test_p#{test_partition}",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000,
      queue_target: 500,
      queue_interval: 5_000
end

# Disable auto-migration in tests — mix aliases handle ecto.migrate
config :arca, auto_migrate: false

# The suite's fake servers (Bypass, a local registry) live on loopback; the
# operator's private-egress allowlist names them, as it would name a real
# internal host. Tests that exercise the refusal override this.
config :sanctum, private_egress_targets: ["localhost", "127.0.0.1/8", "::1"]

# Allow tests to inject a membership-resolution override (Sanctum.Tenancy).
# Compile-time gate: production releases compile this to false and never honor
# the override. See Sanctum.Tenancy "Test overrides".
config :sanctum, allow_tenancy_resolver_override: true

# One app's tests run without the sibling apps' providers; the catalog
# boots leniently here and refuses to elsewhere.
config :sanctum, tool_providers_lenient: true

# Don't run the background retention sweeper in the test supervision tree —
# its periodic DB cleanup conflicts with the Ecto sandbox connection lifecycle.
# Retention logic is exercised directly in Arca.RetentionTest / scheduler unit tests.
config :cyfr, retention_scheduler_enabled: false

# The reconciler reacts to vault broadcasts with DB reads from its own
# process, which races the shared sandbox connection; its own suite
# starts it explicitly.
config :cyfr, external_server_reconciler_enabled: false

# Start the cron scheduler only within its tests so its database work
# stays within the owning test's sandbox lifetime.
config :cyfr, cron_scheduler_enabled: false

# The schedule-notes keeper drains at boot and on a timer: under the
# shared sandbox its tick would work another test's records on the
# connection that test lent. Its own tests start one.
config :cyfr, schedule_notes_enabled: false

# The projection reconciler starts and attaches nothing: its recovery and
# its notifications would reconcile from its own process, on a sandbox
# connection no test owns. Every read's barrier reconciles in the reader,
# and its own suite starts an instance.
config :cyfr, Compendium.ProjectionReconciler, enabled: false

# The boot's security reconcile and seed offer write rows before any
# test's sandbox checkout, so the sandboxed suite boot omits both; their
# own tests run them directly. Omitting the security gate takes BOTH this
# compile-time permission and the runtime switch below: a build compiled
# without the permission — every release — starts the gate whatever the
# switch says (`Cyfr.Application.bootstrap_skipped?/2`).
config :cyfr, bootstrap_skip_permitted: true

# Fixtures that build an issuing context by hand pass the generations its
# rows stand at (`Sanctum.TestContext.snapshot!/1`) as `generation_snapshot:`
# to `Sanctum.Session.create/2` and `Sanctum.ApiKey.create/3`. Compiled in
# here alone: every release refuses the option as a context with no
# generations (`Sanctum.Issuance`).
config :sanctum, issuance_snapshot_permitted: true
config :cyfr, provisioning_boot_enabled: false

# Likewise the thread-runner boot recovery reads the repo before any
# sandbox exists; the runner suite drives recovery itself.
config :cyfr, thread_recovery: false

# Bookkeeping rows are written in the caller: the sandbox connection is the
# test's, and every assertion reads the row right after the call.
config :arca, record_sink_inline: true

# Same for the provisioning retries a sign-in kicks off.
config :sanctum, provisioning_inline: true

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

# The control-plane claim is the same shape again (a permanent process
# renewing a DB lease) and is exercised directly. The key is
# `Arca.ControlPlane`'s, which holds the lease row: off, it answers as a
# member that claims no slot, from the cached standing, and every boot
# holds.
config :arca, control_plane_claim_enabled: false

# The control plane's own pool is off under the SQL sandbox: a second
# connection neither sees nor rolls back a test's rows, and on SQLite it
# waits behind a test's open write. So the control plane writes on the
# sandboxed repo here; the tests of the pool start one of their own,
# outside the sandbox, and the cluster members turn it on.
config :arca, control_plane_pool: false

# SQLite's writers take no turns under the SQL sandbox
# (`Arca.WriteTurn.enabled?/0`): an async test's connection holds the
# write lock until the test ends and its own audit writer runs on it, so a
# writer of another sandbox holding the turn while it waits for that lock,
# and this writer waiting for the turn, would wait on each other until a
# deadline. The tests of the turn turn it on outside the sandbox, and the
# cluster members and the canvas proof's release run it.
config :arca, write_turn: false

# The boot's database checks (schema fingerprint, tenant roster, keyring
# fingerprint) read and write server rows outside any sandbox; the suite
# verifies the schema before it starts and exercises each check directly.
config :cyfr, database_checks_enabled: false

# Default storage roots for tests (individual tests may override), two
# throwaway SIBLING roots — the topology dev and prod use ("two trees, two
# lifetimes", Arca.Storage): `base_path` holds all tenant storage, and the
# seed tree starts with an empty bundle so no test sees one it did not
# write. A root outside the run's own directory would make tests read or
# write the repo's own trees. test_helper.exs copies the shipped AQUA
# template into the throwaway seed tree — it is only ever read in place
# through the overlay. test_helper.exs removes both roots after the suite.
config :arca,
  base_path: Path.join(test_run_root, "data"),
  seed_path: Path.join(test_run_root, "seed")

# Sanctum test configuration
config :sanctum,
  secret_key_base: "test_dev_key_base_min_64_chars_for_aes256_key_derivation_padding!"

# The runtime root every key CYFR issues derives from (`Prima.WorkerAuth`),
# fixed for the suite so the runtime's worker service of a test boot holds the
# key CYFR derives for its id: `worker_key(root, "wrk_local")`, spelled
# here as the HMAC it is (`Prima.MacEnvelope.derive/4`: the label, then the
# service id, one per line) because the contracts are not compiled when
# this file is read. `OpusTest` pins the two spellings to each
# other.
test_worker_root = :crypto.hash(:sha256, "cyfr-test-worker-root")
config :cyfr, :locus_runtime_root, test_worker_root

# The runtime's service of a test boot listens on a port of the system's
# choosing, and so does CYFR's host API listener; `Cyfr.Test.RuntimeService`
# points each at the other's once both are up. Its runners are OS processes
# of their own, started by the test build's direct launcher (`:direct`),
# which its test support compiles and this configuration alone names
# (`Locus.Runtime.Keeper.direct_keeper/0`), and pooled across tests; a
# runner holds no sys.config, so what it takes from this configuration (the
# log level, the scheduler counts) the service passes it explicitly
# (`Locus.Runtime.Release.runner_command/0`).
config :locus, :runtime,
  service_id: "wrk_local",
  service_key:
    :hmac
    |> :crypto.mac(:sha256, test_worker_root, "cyfr-locus/v1/runtime\nwrk_local")
    |> Base.encode16(case: :lower),
  host_url: "http://127.0.0.1:4300",
  bind: "127.0.0.1",
  port: 0,
  keeper: :direct,
  direct_keeper: Locus.DirectLauncher.Runner

config :cyfr, :host_api_port, 0

# The worker services runs are dispatched to (`Opus.Dispatch`), as
# `config/runtime.exs` writes them from CYFR_LOCUS_RUNTIME_WORKERS for every
# other boot: the suite's own runtime service, which
# `Cyfr.Test.RuntimeService` points at its listener once it is up.
config :cyfr, :locus_runtime_workers, [
  %{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}
]

# The checkout's pinned wasm-tools (scripts/wasm-tools.sh install _tools).
config :prima, :wasm_tools, Path.expand("../_tools/wasm-tools", __DIR__)

# Print only warnings and errors during test
config :logger, level: :warning

# The namespace read is cached per person for a minute in production; a
# sandbox rollback is a write no invalidation ever sees, so tests read the
# users row every time.
config :sanctum, :namespace_cache_ttl_ms, 0
