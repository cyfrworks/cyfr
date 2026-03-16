defmodule Opus.MixProject do
  use Mix.Project

  def project do
    [
      app: :opus,
      version: "1.0.1",
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

  def application do
    [
      extra_applications: [:logger],
      mod: {Opus.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [test: ["ecto.create -r Arca.Repo --quiet", "ecto.migrate -r Arca.Repo --quiet", "test"]]
  end

  defp deps do
    [
      {:wasmex, "~> 0.13.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:cyfr, in_umbrella: true},
      {:locus, in_umbrella: true},
      {:dotenvy, "~> 0.9"}
    ]
  end
end
