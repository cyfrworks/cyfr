# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Bundle do
  @moduledoc """
  The seed bundle: the components every athanor starts with.

  Its logical prefix is `seed/components/{type}s/local/{name}/{version}/…`,
  and it is install media, not tenant storage: `Arca` reads it in place from
  the seed tree (`:seed_path`, outside the storage root), nothing indexes it as rows, and
  only server-internal contexts may touch it (`Arca.Storage.authorize_path/2`
  — `seed/` is a reserved root, see `Arca.Storage.seed_roots/0`).
  `Compendium.AthanorSeeder` copies it into a new athanor, whose own scan
  then registers the copies.
  """

  @doc "The bundle root segments: `[\"seed\", \"components\"]`."
  @spec bundle_prefix() :: [String.t()]
  def bundle_prefix, do: ["seed", "components"]

  @doc "The publisher every bundled component ships under."
  def publisher, do: "local"

  @doc "The type directories a bundle carries."
  def type_plurals, do: Compendium.ComponentPath.type_plurals()
end
