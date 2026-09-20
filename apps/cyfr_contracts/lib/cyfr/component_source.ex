# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ComponentSource do
  @moduledoc """
  The ingress-channel vocabulary of a component row's `source` column —
  how its bytes arrived, never whose they are.

  - `"filesystem"` — minted by the scanner from the union: bundled seed
    units and an athanor's own (scaffolded, built, forked) alike.
  - `"published"` — published directly into this registry.
  - `"oci"` — pulled from a remote registry (WASM and tinctures alike).

  Two sides agree on the roster: the component domain classifies a row as
  it writes it, and the row store refuses anything outside `values/0`.
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

  @doc "The closed roster — what the row store admits."
  @spec values() :: [String.t()]
  def values, do: [@filesystem, @published, @oci]
end
