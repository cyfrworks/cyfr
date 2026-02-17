import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :emissary, EmissaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-secret-key-base-minimum-64-characters-long-for-development-only",
  watchers: []

# Prism development configuration
config :prism, PrismWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "prism-dev-secret-key-base-minimum-64-characters-long-for-development-only!",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:prism, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:prism, ~w(--watch)]}
  ]

config :prism, PrismWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"apps/prism/priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/prism/lib/prism_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Set a higher stacktrace during development
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Configure Arca for development
config :arca, Arca.Repo,
  database: "data/dev.db",
  show_sensitive_data_on_connection_error: true

# Sanctum dev configuration
config :sanctum,
  secret_key_base: "dev_secret_key_base_min_64_chars_for_aes256_key_derivation_padding!"

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter,
  format: "[$level] $message\n"

# Enable telemetry console reporter in development
config :emissary, telemetry_console_enabled: true
