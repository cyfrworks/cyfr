# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MixProject do
  use Mix.Project

  def project do
    [
      app: :locus,
      version: "0.5.8",
      build_path: "../../_build",
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Locus.Application, []}
    ]
  end

  # The builder: the shared contracts, its own listener, and nothing of the
  # control plane (`Cyfr.Boundaries` keeps it so). It reads no `.env`
  # file: the `locus` release takes `LOCUS_BUILDS_*` from its process
  # environment alone (`config/locus_runtime.exs`).
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:prima, in_umbrella: true}
    ]
  end
end
