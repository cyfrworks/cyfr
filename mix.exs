defmodule Cyfr.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: umbrella_apps(),
      version: "1.7.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # `:arx` is the commercial extension app — present in the private cyfrworks/arx
  # source of truth, stripped from the public cyfrworks/cyfr FOSS mirror by
  # `.github/workflows/mirror-foss.yml`. Its presence is the single source of
  # truth for "this build can produce a cyfr_arx release" — no separate config
  # flag, no `Code.ensure_loaded?` checks elsewhere in Core.
  defp umbrella_apps do
    base = [:cyfr, :locus, :opus]
    if File.exists?("apps/arx/mix.exs"), do: base ++ [:arx], else: base
  end

  defp deps do
    [
      {:dotenvy, "~> 0.9"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": ["tailwind prism --minify", "esbuild prism --minify", "phx.digest"]
    ]
  end

  defp releases do
    base = [
      cyfr: [
        applications: [
          cyfr: :permanent,
          locus: :permanent,
          opus: :permanent
        ]
      ]
    ]

    if File.exists?("apps/arx/mix.exs") do
      base ++
        [
          cyfr_arx: [
            applications: [
              cyfr: :permanent,
              locus: :permanent,
              opus: :permanent,
              arx: :permanent
            ],
            runtime_config_path: "apps/arx/config/runtime.exs"
          ]
        ]
    else
      base
    end
  end
end
