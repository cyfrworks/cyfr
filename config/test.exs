# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# We don't run a server during test
config :cyfr, EmissaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-minimum-64-characters-long-for-testing-only",
  server: false

config :cyfr, PrismWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "prism-test-secret-key-base-minimum-64-characters-long-for-testing-only!",
  server: false

# Effectively disable the MCP transport rate limit in tests — controller
# suites drive hundreds of /mcp requests from 127.0.0.1 within one window.
# MCPRateLimitTest overrides this per-test to exercise the limiter itself.
config :cyfr, :mcp_rate_limit_max, 1_000_000

# Consent fixtures are seeded in-memory per test; the DB adapter has its
# own dedicated suite.
config :cyfr, :consent_source, Sanctum.Consent.Source.Memory

# Proofs likewise: unit tests run on the ETS store; proof_db_test.exs
# exercises the durable adapter directly.
config :cyfr, :consent_proof_store, Sanctum.Consent.Proof.Memory

# Same for the tincture transport rate limit; TinctureRateLimitTest and the
# tincture controller's 429 tests override this per-test.
config :cyfr, :tincture_rate_limit_max, 1_000_000

# Configure Arca for tests (use sandboxed pool). The adapter is selected at
# build time in config.exs from CYFR_DATABASE; the per-adapter opts must
# match (SQLite-only keys break a Postgres connect, and Postgres needs a URL
# or hostname/credentials to authenticate).
case String.downcase(System.get_env("CYFR_DATABASE", "sqlite")) do
  "sqlite" ->
    config :cyfr, Arca.Repo,
      database: Path.expand("data/test.db"),
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000,
      journal_mode: :wal,
      busy_timeout: 5_000

  "postgres" ->
    config :cyfr, Arca.Repo,
      url:
        System.get_env("CYFR_DATABASE_URL") ||
          "postgres://cyfr:cyfr@localhost:5432/cyfr_test",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 20,
      ownership_timeout: 60_000
end

# Disable auto-migration in tests — mix aliases handle ecto.migrate
config :cyfr, auto_migrate: false

# Allow tests to inject a membership-resolution override (Sanctum.Tenancy).
# Compile-time gate: production releases compile this to false and never honor
# the override. See Sanctum.Tenancy "Test overrides".
config :cyfr, allow_tenancy_resolver_override: true

# Don't run the background retention sweeper in the test supervision tree —
# its periodic DB cleanup conflicts with the Ecto sandbox connection lifecycle.
# Retention logic is exercised directly in Arca.RetentionTest / scheduler unit tests.
config :cyfr, retention_scheduler_enabled: false

# Set a default base_path for tests (individual tests may override)
config :cyfr, base_path: Path.join(System.tmp_dir!(), "cyfr_test_#{System.system_time(:millisecond)}")

# Sanctum test configuration
config :cyfr,
  secret_key_base: "test_dev_key_base_min_64_chars_for_aes256_key_derivation_padding!",
  # Use fewer iterations in tests for speed
  pbkdf2_iterations: 1000,
  # Namespace populated on Context.local() / Context.fixture-shaped contexts.
  # Production contexts should never use this — they get namespace from
  # CredentialStore via the session-resolution path.
  default_test_namespace: "testns"

# Print only warnings and errors during test
config :logger, level: :warning
