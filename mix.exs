# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:cyfr, :locus, :opus],
      version: "0.5.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp deps do
    [
      {:dotenvy, "~> 0.9"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # The tree carries ~1,000 `@spec`s that nothing had ever checked, so a
  # wrong one misled the reader with the authority of a type. The PLT is
  # cached under `_build` so CI builds it once per OTP/Elixir/deps change.
  #
  # `:underspecs` and friends are deliberately off: the goal is to catch
  # specs that contradict the code, not to argue about ones that are merely
  # wider than it.
  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit, :eex],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": ["tailwind prism --minify", "esbuild prism --minify", "phx.digest"]
    ]
  end

  defp releases do
    [
      cyfr: [
        applications: [
          cyfr: :permanent,
          locus: :permanent,
          opus: :permanent
        ]
      ],
      # The builder container: the toolchain half of Locus and nothing
      # else. The cyfr app is LOADED (the pure modules Locus.Builder
      # reaches — Cyfr.{PathSafety,Digest,LoggerContext},
      # Compendium.{WasmValidator,Scaffold,WITSource}, and the
      # FSL-licensed Sanctum.Limits — compile into the build path) but
      # never STARTED: no endpoint, no repo, no tenant state.
      builder: [
        applications: [
          locus: :permanent,
          cyfr: :load
        ]
      ]
    ]
  end
end
