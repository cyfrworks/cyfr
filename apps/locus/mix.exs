# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.MixProject do
  use Mix.Project

  def project do
    [
      app: :locus,
      version: "0.5.8",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp aliases do
    [test: ["ecto.create -r Arca.Repo --quiet", "ecto.migrate -r Arca.Repo --quiet", "test"]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Locus.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4", only: :test},
      {:cyfr, in_umbrella: true}
    ]
  end
end
