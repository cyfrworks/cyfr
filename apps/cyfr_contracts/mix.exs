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

  # Pure contracts and the finite shared runtime primitive roster: Boot,
  # RateLimiter, LoggerContext, JsonFormatter, Slots and Caps. This app starts
  # no process; applications own process instances and install the Caps port.
  # Network only parses URLs, checks supplied addresses and builds options:
  # DNS/configuration and HTTP stay in the applications that own those effects.
  defp deps do
    [{:jason, "~> 1.4"}]
  end
end
