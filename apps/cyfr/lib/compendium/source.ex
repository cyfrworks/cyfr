# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Source do
  @moduledoc """
  The ingress-channel vocabulary of the components table's `source`
  column — how a row's bytes arrived, never whose they are (that is
  derived from the tree; see `Compendium.Provenance`):

  - `"filesystem"` — minted by the scanner from the union: bundled seed
    units and the athanor's own (scaffolded, built, forked) alike.
  - `"published"` — published directly into this registry.
  - `"oci"` — pulled from a remote registry (WASM and tinctures alike).

  `remote?/1` is the one predicate provenance derives `:remote` from;
  `values/0` is the closed roster the schema validates against.
  """

  @filesystem "filesystem"
  @published "published"
  @oci "oci"

  @doc "The scanner's ingress — bundled and user-created rows alike."
  @spec filesystem() :: String.t()
  def filesystem, do: @filesystem

  @doc "Published directly into this registry."
  @spec published() :: String.t()
  def published, do: @published

  @doc "Pulled from a remote registry."
  @spec oci() :: String.t()
  def oci, do: @oci

  @doc "The closed roster — what the schema admits."
  @spec values() :: [String.t()]
  def values, do: [@filesystem, @published, @oci]

  @doc """
  Whether the source names registry-sourced bytes — the one input the
  provenance derivation takes from the row.

  ## Examples

      iex> Compendium.Source.remote?("oci")
      true

      iex> Compendium.Source.remote?("filesystem")
      false

  """
  @spec remote?(term()) :: boolean()
  def remote?(source), do: to_string(source) in [@oci, @published]
end
