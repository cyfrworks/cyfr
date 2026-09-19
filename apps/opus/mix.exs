# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MixProject do
  use Mix.Project

  def project do
    [
      app: :opus,
      version: "0.5.8",
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

  def application do
    [
      extra_applications: [:logger, :crypto],
      env: env(Mix.env()),
      mod: {Opus.Application, []}
    ]
  end

  # The umbrella starts every app before a suite's helper runs, so the
  # test environment carries bootable defaults: a worker service on this
  # machine, listening on a port a test asks for, with a key the suites
  # replace (`test/test_helper.exs`, the cyfr integration suite), running
  # its runners as OS processes of their own (the `:direct` keeper). Every
  # other environment configures the credentials or refuses to boot
  # (`Opus.Credentials`), and takes the pool's defaults from
  # `Opus.Settings`.
  defp env(:test) do
    [
      service_id: "wrk_local",
      service_key: String.duplicate("0", 64),
      host_url: "http://127.0.0.1:4300",
      bind: "127.0.0.1",
      port: 0,
      keeper: :direct
    ]
  end

  defp env(_env), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The suite starts the application itself (`test/test_helper.exs`), once
  # it has given the worker service the credentials its scripted host
  # verifies.
  defp aliases, do: [test: ["test --no-start"]]

  # The WASM engine and its worker service: the shared contracts, the
  # runtime, its own listener and its client of CYFR's host API, and the
  # `.env` reader the `opus` release's `config/runtime.exs` takes its
  # `OPUS_*` settings through. Nothing of the control plane:
  # `Opus.HostSurfaceTest` keeps it so.
  defp deps do
    [
      {:wasmex, "~> 0.13.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:dotenvy, "~> 0.9"},
      {:cyfr_contracts, in_umbrella: true}
    ]
  end
end
