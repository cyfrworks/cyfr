# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentId do
  @moduledoc """
  Canonical component identity hash.

  The id is `comp_<16 hex>` where the hex is the first 8 bytes of
  `sha256("<athanor_id>:<publisher>:<name>:<version>:<type>")`. The
  publisher is normalized through `Compendium.ComponentPath.normalize_publisher/1`
  (the same chokepoint the on-disk path uses), so the id can never diverge
  from the component's storage path. The athanor id is taken as given —
  there is no sentinel a missing one could stand for, so it must be
  resolved.

  Every id is computed through this one function so producers can never
  diverge — the same coordinate hashed two ways in two places would mint
  two different ids for one component.
  """

  alias Compendium.ComponentPath

  @doc "Compute the canonical `comp_<hash>` id for a component coordinate."
  @spec compute(String.t(), String.t(), String.t() | nil, String.t() | nil, String.t()) ::
          String.t()
  def compute(name, version, publisher, component_type, athanor_id)
      when is_binary(athanor_id) and athanor_id != "" do
    publisher = ComponentPath.normalize_publisher(publisher)
    component_type = component_type || ""

    hash =
      :crypto.hash(:sha256, "#{athanor_id}:#{publisher}:#{name}:#{version}:#{component_type}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "comp_#{hash}"
  end
end
