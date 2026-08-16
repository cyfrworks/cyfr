# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Bundle do
  @moduledoc """
  The seed bundle: the components every athanor starts with.

  It lives at `components/_bundle/{type}s/local/{name}/{version}/…` — beside
  the athanor trees, but never a tenant: nothing indexes it as rows and only
  server-internal contexts may read it (`Arca.Storage.authorize_path/2`).
  `Compendium.AthanorSeeder` copies it into a new athanor, whose own scan then
  registers the copies.
  """

  @segment "_bundle"

  @doc "The bundle root segments: `[\"components\", \"_bundle\"]`."
  @spec bundle_prefix() :: [String.t()]
  def bundle_prefix, do: ["components", @segment]

  @doc "The reserved segment name; not a valid slug, so it can never be an athanor."
  def segment, do: @segment

  @doc "The publisher every bundled component ships under."
  def publisher, do: "local"

  @doc "The type directories a bundle carries."
  def type_plurals, do: Compendium.ComponentPath.type_plurals()
end
