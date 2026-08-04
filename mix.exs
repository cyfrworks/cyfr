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
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp deps do
    [
      {:dotenvy, "~> 0.9"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
      ]
    ]
  end
end
