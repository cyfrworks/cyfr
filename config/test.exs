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

# Configure Arca for tests (use sandboxed pool). The adapter is selected at
# compile time in config.exs from CYFR_BUILD_FOR; the per-adapter opts must
# match (SQLite-only keys break a Postgres connect, and Postgres needs a URL
# or hostname/credentials to authenticate).
if System.get_env("CYFR_BUILD_FOR") == "arx" do
  # Align runtime :edition with the compile-time adapter switch in config.exs.
  # Without this, Postgres-leg tests run with :edition default (:core), so
  # any Arx-edition-gated code path silently takes the Core branch unless the
  # test explicitly Application.put_env(:cyfr, :edition, :arx).
  config :cyfr, :edition, :arx

  config :cyfr, Arca.Repo,
    url:
      System.get_env("CYFR_DATABASE_URL") ||
        "postgres://cyfr:cyfr@localhost:5432/cyfr_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 20,
    ownership_timeout: 60_000
else
  config :cyfr, Arca.Repo,
    database: Path.expand("data/test.db"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 20,
    ownership_timeout: 60_000,
    journal_mode: :wal,
    busy_timeout: 5_000
end

# Disable auto-migration in tests — mix aliases handle ecto.migrate
config :cyfr, auto_migrate: false

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
