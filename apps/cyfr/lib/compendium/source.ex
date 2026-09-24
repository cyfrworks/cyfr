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
  `values/0` is the closed roster the row store enforces
  (`Arca.ComponentStorage` refuses to write anything outside it).

  The roster itself is `Prima.ComponentSource`, where the row store reads
  it too; this module is the component domain's spelling of it and the
  home of the provenance predicate.
  """

  @published Prima.ComponentSource.published()
  @oci Prima.ComponentSource.oci()

  @doc "The scanner's ingress — bundled and user-created rows alike."
  @spec filesystem() :: String.t()
  defdelegate filesystem(), to: Prima.ComponentSource

  @doc "Published directly into this registry."
  @spec published() :: String.t()
  defdelegate published(), to: Prima.ComponentSource

  @doc "Pulled from a remote registry."
  @spec oci() :: String.t()
  defdelegate oci(), to: Prima.ComponentSource

  @doc "The closed roster — what the row store admits."
  @spec values() :: [String.t()]
  defdelegate values(), to: Prima.ComponentSource

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
