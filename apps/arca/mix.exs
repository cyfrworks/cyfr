# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MixProject do
  use Mix.Project

  def project do
    [
      app: :arca,
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arca.Supervisor, []}
    ]
  end

  # Persistence and nothing above it: the schemas, the queries, the
  # transactions, the blob doors, the cache and the leases, over the
  # shapes the contracts own. Both database drivers ship in every build —
  # the single switch is CYFR_DATABASE, which flips `:arca, :repo_adapter`
  # at compile time — and so does the S3 object-store adapter, opt-in via
  # `:arca, :storage_adapter`.
  defp deps do
    [
      {:cyfr_contracts, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.22.0"},
      {:exqlite, "~> 0.22"},
      {:postgrex, "~> 0.21"},
      {:jason, "~> 1.4"},
      # The S3 storage adapter: its transport and its SigV4 signing.
      {:req, "~> 0.5"},
      {:aws_signature, "~> 0.3"},
      # `Arca.Adapters.Local` serves a stored object straight onto a
      # `Plug.Conn`, which is where the file door ends.
      {:plug, "~> 1.14"},
      {:telemetry, "~> 1.0"}
    ]
  end

  defp aliases do
    [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
  end
end
