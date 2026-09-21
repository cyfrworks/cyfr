# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:cyfr_contracts, :arca, :sanctum, :cyfr, :locus, :opus],
      version: "0.5.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # The step bench builds its estate from test fixtures in the test database.
  def cli do
    [preferred_envs: ["cyfr.bench.step": :test]]
  end

  defp deps do
    [
      {:dotenvy, "~> 0.9"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Cache Dialyzer PLTs under _build and check for specs that contradict the code.
  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit, :eex],
      flags: [:error_handling, :extra_return, :missing_return],
      # Apply reviewed warning filters and fail on unused entries.
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "cyfr.bench.step": ["ecto.create --quiet", "ecto.migrate --quiet", "cyfr.bench.step"],
      "assets.deploy": ["tailwind prism --minify", "esbuild prism --minify", "phx.digest"]
    ]
  end

  defp releases do
    [
      # The control plane. Execution workers run in the `opus` release and
      # builds in the `locus` release, each reached over its wire; the
      # control plane starts neither.
      cyfr: [
        applications: [
          cyfr_contracts: :permanent,
          arca: :permanent,
          sanctum: :permanent,
          cyfr: :permanent
        ]
      ],
      # The execution worker: the WASM engine and its worker service on the
      # shared contracts, and nothing of the control plane
      # (`Opus.HostSurfaceTest`). It holds one derived worker key and
      # reaches CYFR's host API over HTTP.
      opus: [
        applications: [
          cyfr_contracts: :permanent,
          opus: :permanent
        ]
      ],
      # The builder: Locus on the shared contracts, and nothing of the
      # control plane (`Locus.HostSurfaceTest`). It holds one builds key,
      # reads `LOCUS_BUILDS_*` through its own runtime configuration, and is
      # reached by CYFR over the build wire (`Cyfr.BuilderProtocol`).
      locus: [
        applications: [
          cyfr_contracts: :permanent,
          locus: :permanent
        ],
        runtime_config_path: "config/locus_runtime.exs"
      ]
    ]
  end
end
