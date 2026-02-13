# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx.MixProject do
  use Mix.Project

  def project do
    [
      app: :sanctum_arx,
      version: "0.10.4",
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
      mod: {SanctumArx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sanctum, in_umbrella: true},
      # OIDC providers for enterprise auth
      {:ueberauth_oidcc, "~> 0.4.2"},
      {:ueberauth_github, "~> 0.8.3"},
      {:ueberauth_google, "~> 0.12.1"},
      # Plug for conn handling in auth
      {:plug, "~> 1.14"}
    ]
  end
end
