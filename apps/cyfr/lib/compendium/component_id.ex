# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentId do
  @moduledoc """
  Canonical component identity hash.

  The id is `comp_<16 hex>` where the hex is the first 8 bytes of
  `sha256("<org>:<project>:<publisher>:<name>:<version>:<type>")`. Tenant
  fields are normalized through `Arca.QueryHelpers` and the publisher through
  `Compendium.ComponentPath.normalize_publisher/1` (the same chokepoint the
  on-disk path uses), so `nil`/`""` collapse to the seeded `local`/`default`
  sentinels and the id can never diverge from the component's storage path.

  Every id is computed through this one function so producers can never
  diverge — an org-less row hashed `local` in one place and `""` in another
  would mint two different ids for the same component.
  """

  alias Arca.QueryHelpers
  alias Compendium.ComponentPath

  @doc "Compute the canonical `comp_<hash>` id for a component coordinate."
  @spec compute(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: String.t()
  def compute(name, version, publisher, component_type, org_id, project_id) do
    publisher = ComponentPath.normalize_publisher(publisher)
    component_type = component_type || ""
    org = QueryHelpers.normalize_org_id(org_id)
    proj = QueryHelpers.normalize_project_id(project_id)

    hash =
      :crypto.hash(:sha256, "#{org}:#{proj}:#{publisher}:#{name}:#{version}:#{component_type}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "comp_#{hash}"
  end
end
