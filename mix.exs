# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:prima, :arca, :sanctum, :cyfr, :locus],
      version: "0.6.0-alpha.4",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      # The code reloader's compile listener serves the dev server alone; a
      # build of the Locus image's umbrella has no Phoenix to start it.
      listeners: if(Mix.env() == :dev, do: [Phoenix.CodeReloader], else: [])
    ]
  end

  # The step bench builds its athanor from test fixtures in the test database.
  def cli do
    [preferred_envs: ["cyfr.bench.step": :test]]
  end

  defp deps do
    [
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
      test: [&test_after_database/1],
      "cyfr.bench.step": ["ecto.create --quiet", "ecto.migrate --quiet", "cyfr.bench.step"],
      "assets.deploy": ["tailwind prism --minify", "esbuild prism --minify", "phx.digest"]
    ]
  end

  # `mix test` prepares the database, then tests. The database steps take
  # the compile switches from the same arguments, because a string alias
  # hands its arguments to the last step only: a root `compile` inside one
  # partition of `scripts/test-partitioned.sh` deletes and rebuilds the
  # umbrella's shared protocol consolidation (every child compiles with
  # consolidation off and cleans the shared path first) while the other
  # partitions are loading from it.
  defp test_after_database(args) do
    switches = Enum.filter(args, &(&1 in ["--no-compile", "--no-deps-check"]))
    Mix.Task.run("ecto.create", ["--quiet" | switches])
    Mix.Task.run("ecto.migrate", ["--quiet" | switches])
    Mix.Task.run("test", args)
  end

  defp releases do
    [
      # The control plane. The runtime, builds and backends run in the
      # `locus` release, each role reached over its wire; the control plane
      # starts none of them.
      cyfr: [
        applications: [
          prima: :permanent,
          arca: :permanent,
          sanctum: :permanent,
          cyfr: :permanent
        ]
      ],
      # The island: Locus on the shared contracts, and nothing of the
      # control plane. A node serves each role whose key it holds: the
      # runtime (the WASM engine and its worker service, reaching CYFR's
      # host API over HTTP), builds and backends, each reached by CYFR over
      # its wire. It reads every role's settings through its own runtime
      # configuration.
      locus: [
        applications: [
          prima: :permanent,
          locus: :permanent
        ],
        runtime_config_path: "config/locus_runtime.exs"
      ]
    ]
  end
end
