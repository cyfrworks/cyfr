# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrContracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyfr_contracts,
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
    [extra_applications: [:logger, :crypto]]
  end

  # The pure primitives every app shares — the control plane, the execution
  # worker and the builder. No database, no process, no configuration read.
  #
  # No HTTP client either, deliberately: `Cyfr.Network` decides where an
  # outbound request may connect and answers the options that connect
  # there, and each app that actually speaks HTTP issues the request with
  # its own `req`. The builder island depends on these contracts and on
  # three other packages; an HTTP client reaching its release through here
  # would be one more thing a compromised build service has to hand.
  defp deps do
    [{:jason, "~> 1.4"}]
  end
end
