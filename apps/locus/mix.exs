# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MixProject do
  use Mix.Project

  def project do
    [
      app: :locus,
      version: "0.6.0-alpha.2",
      build_path: "../../_build",
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      env: env(Mix.env()),
      mod: {Locus.Application, []}
    ]
  end

  # The test build runs its builds and backends without cyfr-locus
  # through `Locus.DirectLauncher`, which isolates and bounds nothing and
  # is compiled from `test/support` alone (`Locus.Executor.direct_launcher/0`).
  # Every other build names no launcher and compiles none. The runtime's
  # direct keeper is named by the test configuration alone (`config :locus,
  # :runtime` in the umbrella's `config/test.exs` and this app's
  # `config/config.exs`), since a configured `:runtime` keyword replaces a
  # default given here whole.
  defp env(:test), do: [direct_launcher: Locus.DirectLauncher]
  defp env(_env), do: []

  # The suite starts the application itself (`test/test_helper.exs`), once
  # it has given the worker service the credentials its scripted host
  # verifies.
  defp aliases, do: [test: ["test --no-start"]]

  # Every role of the release: the shared contracts, each role's own
  # listener, the runtime's WASM engine (`wasmex`) and its client of
  # CYFR's host API (`req`), and nothing of the control plane
  # (`Cyfr.Boundaries` keeps it so). It reads no `.env` file: the `locus`
  # release takes every role's settings from its process environment alone
  # (`config/locus_runtime.exs`).
  defp deps do
    [
      {:wasmex, "~> 0.15.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:prima, in_umbrella: true}
    ]
  end
end
