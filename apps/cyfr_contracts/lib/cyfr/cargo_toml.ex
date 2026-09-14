# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CargoToml do
  @moduledoc """
  The canonical Cargo.toml a Rust component project builds with: one
  template for the component scaffold (`Compendium.Scaffold`) and the
  build sandbox (`Locus.Builder`).
  """

  @doc """
  The Cargo.toml template for a component type: `:reagent`, `:catalyst` or
  `:formula`.

  ## Options

    * `:include_oauth_wit` — whether the catalyst template binds the
      `cyfr:oauth` WIT dependency (default `true`). The build path passes
      `false`: it materializes only the WIT worlds every catalyst needs,
      and a user project that uses oauth declares it in its own Cargo.toml,
      which the builder treats as authoritative for WIT deps.
  """
  @spec template(:reagent | :catalyst | :formula, keyword()) :: String.t()
  def template(type, opts \\ [])

  def template(:reagent, _opts) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:reagent"

    [package.metadata.component.target]
    world = "reagent"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def template(:catalyst, opts) do
    wit_deps =
      [
        ~s("cyfr:vault" = { path = "wit/deps/cyfr-vault" }),
        ~s("cyfr:http" = { path = "wit/deps/cyfr-http" }),
        ~s("cyfr:storage" = { path = "wit/deps/cyfr-storage" }),
        ~s("cyfr:emit" = { path = "wit/deps/cyfr-emit" })
      ] ++
        if Keyword.get(opts, :include_oauth_wit, true),
          do: [~s("cyfr:oauth" = { path = "wit/deps/cyfr-oauth" })],
          else: []

    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:catalyst"

    [package.metadata.component.target]
    world = "catalyst"
    path = "wit"

    [package.metadata.component.target.dependencies]
    #{Enum.join(wit_deps, "\n")}

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def template(:formula, _opts) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:formula"

    [package.metadata.component.target]
    world = "formula"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end
end
