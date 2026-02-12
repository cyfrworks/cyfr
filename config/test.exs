import Config

# We don't run a server during test
config :emissary, EmissaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-minimum-64-characters-long-for-testing-only",
  server: false

# Configure Arca for tests (use sandboxed pool)
config :arca, Arca.Repo,
  database: "data/test.db",
  pool: Ecto.Adapters.SQL.Sandbox

# Disable auto-migration in tests — mix aliases handle ecto.migrate
config :arca, auto_migrate: false

# Set a default base_path for tests (individual tests may override)
config :arca, base_path: Path.join(System.tmp_dir!(), "cyfr_test_#{System.system_time(:millisecond)}")

# Sanctum test configuration
config :sanctum,
  secret_key_base: "test_dev_key_base_min_64_chars_for_aes256_key_derivation_padding!",
  # Use fewer iterations in tests for speed
  pbkdf2_iterations: 1000

# Print only warnings and errors during test
config :logger, level: :warning
