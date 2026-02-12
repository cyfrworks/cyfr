defmodule Opus.MixProject do
  use Mix.Project

  def project do
    [
      app: :opus,
      version: "0.10.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Opus.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:wasmex, "~> 0.14.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:sanctum, in_umbrella: true},
      {:arca, in_umbrella: true},
      {:emissary, in_umbrella: true},
      {:compendium, in_umbrella: true},
      {:locus, in_umbrella: true}
    ]
  end
end
