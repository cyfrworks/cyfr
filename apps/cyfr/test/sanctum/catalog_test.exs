# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CatalogTest do
  use ExUnit.Case, async: false

  alias Sanctum.Catalog

  test "the one implementation is the operation catalog, and it answers the port" do
    assert Catalog.impl() == Cyfr.Ops.Catalog

    behaviours =
      Cyfr.Ops.Catalog.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Sanctum.Catalog in behaviours

    actions = Catalog.tool_actions()
    assert "system.status" in actions
    assert Enum.all?(actions, &(&1 =~ ~r/^[a-z_]+\.[a-z_]+$/))
  end

  test "a shape derives its tool roster through the port" do
    assert Sanctum.Consent.ShapeDerivation.all_tool_actions() == Catalog.tool_actions()
  end
end
