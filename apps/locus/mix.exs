# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MixProject do
  use Mix.Project

  def project do
    [
      app: :locus,
      version: "0.5.7",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Library-only app: Locus.Builder/Validator/MCP are called by cyfr and
  # need no process tree of their own.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:cyfr, in_umbrella: true},
      {:dotenvy, "~> 0.9"}
    ]
  end
end
