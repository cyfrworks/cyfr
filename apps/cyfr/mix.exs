# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.App.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyfr,
      version: "0.5.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0", "FSL-1.1-Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/cyfrworks/cyfr",
        "License Q&A" => "https://github.com/cyfrworks/cyfr/blob/main/FAIR_SOURCE.md"
      }
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
      # Arca storage/DB deps. Both DB drivers ship in every build; the single
      # switch is CYFR_DATABASE, which flips :repo_adapter at compile time
      # (SQLite is the default, Postgres is opt-in / bring-your-own). The S3
      # object-store adapter (req + aws_signature, below) ships but is opt-in
      # via :storage_adapter — the local filesystem adapter is the default.
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.22.0"},
      {:exqlite, "~> 0.22"},
      {:postgrex, "~> 0.21"},
      # Req is used by Opus HTTP host functions (apps/opus) and the S3
      # storage adapter (apps/cyfr/lib/arca/adapters/s3.ex).
      {:req, "~> 0.5"},
      # SigV4 signing for the S3 storage adapter (opt-in via :storage_adapter).
      {:aws_signature, "~> 0.3"},
      # Emissary deps
      {:phoenix, "~> 1.8.6"},
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
      {:bandit, "~> 1.11"},
      {:finch, "~> 0.19"},
      # OIDC strategy (used by the OIDC auth provider)
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
