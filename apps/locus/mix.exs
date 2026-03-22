defmodule Locus.MixProject do
  use Mix.Project

  def project do
    [
      app: :locus,
      version: "1.2.3",
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
    [
      extra_applications: [:logger],
      mod: {Locus.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:cyfr, in_umbrella: true},
      {:dotenvy, "~> 0.9"}
    ]
  end
end
