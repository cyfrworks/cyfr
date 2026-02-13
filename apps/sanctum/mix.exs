# SPDX-License-Identifier: Apache-2.0
# Copyright 2024 CYFR Contributors

defmodule Sanctum.MixProject do
  use Mix.Project

  def project do
    [
      app: :sanctum,
      version: "0.11.4",
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
      mod: {Sanctum.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core dependencies for Sanctum
      {:ueberauth, "~> 0.10.8"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},

      # Simple OAuth providers for single-user scenarios (GitHub/Google)
      {:ueberauth_github, "~> 0.8.3"},
      {:ueberauth_google, "~> 0.12.1"},
      {:plug, "~> 1.14"}

      # Note: Sanctum uses modules from arca, opus, and emissary at runtime
      # but cannot declare them as compile-time deps due to circular dependencies.
      # These calls work because all apps are loaded into the same BEAM VM.

      # Enterprise OIDC providers (ueberauth_oidcc for Okta, Azure AD, etc.)
      # are in sanctum_arx for Sanctum Arx
    ]
  end
end
