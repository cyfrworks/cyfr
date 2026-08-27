# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# Prometheus metrics stay on in dev (loopback bind, no exposure).
config :cyfr, :prometheus_metrics_enabled, true

# For development, we disable any cache and enable
# debugging and code reloading.
config :cyfr, EmissaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-secret-key-base-minimum-64-characters-long-for-development-only",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:prism, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:prism, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"apps/cyfr/priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/cyfr/lib/prism_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Set a higher stacktrace during development
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Configure Arca for development. One database, one name: runtime.exs
# resolves the same data/cyfr.db (CYFR_DATABASE_PATH-overridable) for dev
# and prod alike; this line only adds the dev-only connection option, since
# config/2 merges keyword lists. Expanded at config time — an unexpanded
# relative path resolves against whichever umbrella app's CWD loads it and
# litters apps/*/data/ with stray databases.
config :cyfr, Arca.Repo,
  database: Path.expand("data/cyfr.db"),
  show_sensitive_data_on_connection_error: true

# Sanctum dev configuration
config :cyfr,
  secret_key_base: "dev_secret_key_base_min_64_chars_for_aes256_key_derivation_padding!"

# No timestamps in development logs, but keep $metadata: LoggerContext's
# request/user/athanor tags are exactly what debugging needs, and dropping
# them made the structured-logging SSOT invisible in the one environment
# where people read logs.
config :logger, :default_formatter, format: "$metadata[$level] $message\n"

# Enable telemetry console reporter in development
config :cyfr, telemetry_console_enabled: true
