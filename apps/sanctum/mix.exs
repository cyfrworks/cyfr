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
      compilers: compilers(Mix.env()),
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

  # The Boundary compiler checks every layer edge in dev and prod; the
  # forced dev compile with warnings as errors is the enforcement. Test
  # support reaches internals by design, because a test tests what it
  # tests, so the test environment compiles without it.
  defp compilers(:test), do: Mix.compilers()
  defp compilers(_env), do: [:boundary] ++ Mix.compilers()

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
      # The layer edges as compile errors: the Boundary compiler checks
      # every `use Boundary` declaration in this application.
      {:boundary, "~> 0.11.0", runtime: false},
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
      # WebAuthn: passkey registration and assertion verification. Pinned,
      # and the only WebAuthn dependency (the plan's §7 seams).
      {:wax_, "== 0.7.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end

  defp aliases do
    [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
  end
end
