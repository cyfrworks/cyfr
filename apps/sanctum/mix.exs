# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MixProject do
  use Mix.Project

  def project do
    [
      app: :sanctum,
      version: "0.5.8",
      build_path: "../../_build",
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # The one FSL zone. Every other app in the umbrella is Apache-2.0 alone.
  defp package do
    [
      licenses: ["FSL-1.1-Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/cyfrworks/cyfr",
        "License Q&A" => "https://github.com/cyfrworks/cyfr/blob/main/FAIR_SOURCE.md"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Sanctum.Supervisor, []}
    ]
  end

  # Identity, tenancy, authority, consent, the vault and the caps, over
  # the contracts' shapes and Arca's rows. Zero Ecto: every query it
  # needs is a facade call downward.
  defp deps do
    [
      {:prima, in_umbrella: true},
      {:arca, in_umbrella: true},
      {:jason, "~> 1.4"},
      # Contexts are established at the authentication boundary, which is
      # a `Plug.Conn`, and the identity providers are Ueberauth strategies.
      {:plug, "~> 1.14"},
      {:ueberauth, "~> 0.10.8"},
      {:ueberauth_oidcc, "~> 0.4.2"},
      # The auth sliver's own HTTP: the device-flow pool
      # (`Sanctum.Auth.Finch`) and the OAuth token exchange.
      {:finch, "~> 0.19"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      # Notifications are broadcast on the server the host names.
      {:phoenix_pubsub, "~> 2.1"},
      # `Phoenix.Token` signs the two tincture tokens
      # (`Sanctum.TinctureAuth`). A signing primitive, not a web surface:
      # this app serves no route and mounts no endpoint.
      {:phoenix, "~> 1.8.6"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end

  defp aliases do
    [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
  end
end
