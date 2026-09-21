# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.App.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyfr,
      version: "0.5.8",
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
      licenses: ["Apache-2.0"],
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
      {:cyfr_contracts, in_umbrella: true},
      # Persistence and the auth domain, each its own application: Arca
      # owns every row, blob and lease; Sanctum owns identity, tenancy,
      # authority, consent and the vault, and reaches Arca downward.
      {:arca, in_umbrella: true},
      {:sanctum, in_umbrella: true},
      {:jason, "~> 1.4"},
      # AQUA agent/skill frontmatter (Compendium.AquaAgent)
      {:yaml_elixir, "~> 2.12"},
      {:plug, "~> 1.14"},
      {:phoenix_pubsub, "~> 2.1"},
      # How the members of a cell find each other. Declared here, in wave 0
      # of the multi-node work, so the shared lock is settled before the
      # targets that use it run side by side; `Cyfr.Cell` starts the
      # supervisor and `config/runtime.exs` carries the topology.
      {:libcluster, "~> 3.5"},
      # The Ueberauth route table the web face builds from the configured
      # providers (`EmissaryWeb.Plugs.ConfiguredUeberauth`); the strategies
      # themselves are Sanctum's.
      {:ueberauth, "~> 0.10.8"},
      # Ecto, for the errors the surfaces rescue and the sandbox the suite
      # runs on. The adapters and the drivers are Arca's.
      {:ecto_sql, "~> 3.12"},
      # Req is used by Opus HTTP host functions (apps/opus) and by
      # `Cyfr.Egress`.
      {:req, "~> 0.5"},
      # Emissary deps
      {:phoenix, "~> 1.8.6"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:bandit, "~> 1.11"},
      {:finch, "~> 0.19"},
      # Prism deps
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      # Shared (needed by config/runtime.exs)
      {:dotenvy, "~> 0.9"},
      # Security
      {:sobelow, "~> 0.13", only: :dev, runtime: false},
      # Test-only
      {:bypass, "~> 2.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
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
