defmodule Cyfr.App.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyfr,
      version: "1.7.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Cyfr.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Sanctum deps
      {:ueberauth, "~> 0.10.8"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:ueberauth_github, "~> 0.8.3"},
      {:ueberauth_google, "~> 0.12.1"},
      {:plug, "~> 1.14"},
      {:phoenix_pubsub, "~> 2.1"},
      # Arca deps — Core ships SQLite only. Postgres support and the S3
      # adapter live in `apps/arx/` so the FOSS mirror has zero cloud-storage
      # / Postgres surface area. See `apps/arx/mix.exs`.
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.22.0"},
      {:exqlite, "~> 0.22"},
      # Req is used by Opus HTTP host functions (apps/opus); kept in Core
      # because it's not Arx-specific.
      {:req, "~> 0.5"},
      # Emissary deps
      {:phoenix, "~> 1.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:dns_cluster, "~> 0.2.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:bandit, "~> 1.10"},
      {:finch, "~> 0.19"},
      # Arx deps
      {:ueberauth_oidcc, "~> 0.4.2"},
      # Prism deps
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      # Shared (needed by config/runtime.exs)
      {:dotenvy, "~> 0.9"},
      # Security
      {:sobelow, "~> 0.13", only: :dev, runtime: false},
      # Test-only
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
