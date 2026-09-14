# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrContracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyfr_contracts,
      version: "0.5.8",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  # The pure primitives every app shares — the control plane, the execution
  # worker and the builder. No database, no process, no configuration read.
  defp deps do
    [{:jason, "~> 1.4"}]
  end
end
