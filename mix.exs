defmodule Cyfr.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:arca, :compendium, :emissary, :locus, :opus, :sanctum, :sanctum_arx],
      version: "0.10.3",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp deps do
    [
      {:dotenvy, "~> 0.9"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp releases do
    [
      # Sanctum - Base Sanctum (Apache 2.0)
      # No license validation, full local functionality
      cyfr: [
        applications: [
          dotenvy: :load,
          sanctum: :permanent,
          arca: :permanent,
          emissary: :permanent,
          compendium: :permanent,
          locus: :permanent,
          opus: :permanent
        ]
      ],

      # Sanctum Arx - Sanctum Arx (FSL 1.1)
      # Requires license validation, additional enterprise features
      cyfr_arx: [
        applications: [
          dotenvy: :load,
          sanctum: :permanent,
          sanctum_arx: :permanent,
          arca: :permanent,
          emissary: :permanent,
          compendium: :permanent,
          locus: :permanent,
          opus: :permanent
        ],
        config_providers: [{Config.Reader, {:system, "RELEASE_ROOT", "/releases/#{Mix.Project.config()[:version]}/arx_runtime.exs"}}]
      ]
    ]
  end
end
