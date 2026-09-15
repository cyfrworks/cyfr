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
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      {:jason, "~> 1.4"},
      # The builder service's HTTP face and the client's transport.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:cyfr_contracts, in_umbrella: true},
      # runtime: false so the `builder` release can start :locus with the
      # cyfr app LOADED but not STARTED — the build path reaches only the
      # contracts, never cyfr's supervision tree.
      # The cyfr release starts :cyfr explicitly, and its ordering in the
      # root mix.exs is what guarantees :cyfr boots first there — OTP has
      # no edge for it. The one locus module that DOES need the started
      # app (Locus.MCP: Repo, Arca, the operation catalog) is reachable only
      # through Cyfr.Ops.Catalog dispatch, which never runs in the builder.
      {:cyfr, in_umbrella: true, runtime: false}
    ]
  end
end
