# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentTest do
  @moduledoc """
  Component resolution returns human-readable `{:error, binary}` results
  for malformed references, missing components, and storage faults.
  `Compendium.MCP.Shared` delegates resolution to this module.
  """

  use ExUnit.Case, async: false

  alias Compendium.Component

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a malformed reference answers the invalid-format message", %{ctx: ctx} do
    assert {:error, "Invalid reference format: " <> _} =
             Component.resolve_component(ctx, "not a ref !!")
  end

  test "a non-binary reference answers, never raises", %{ctx: ctx} do
    assert {:error, "Reference must be a string"} = Component.resolve_component(ctx, 42)
  end

  test "an unknown component answers not-found", %{ctx: ctx} do
    assert {:error, "Component not found: " <> _} =
             Component.resolve_component(ctx, "reagent:local.no-such-thing:9.9.9")
  end

  test "the MCP tool surface delegates — the two resolvers cannot drift", %{ctx: ctx} do
    for reference <- ["not a ref !!", "reagent:local.no-such-thing:9.9.9"] do
      assert Compendium.MCP.Shared.resolve_component(ctx, reference) ==
               Component.resolve_component(ctx, reference)
    end

    assert Compendium.MCP.Shared.parse_reference("c:local.tool:1.0.0") ==
             Component.parse_reference("c:local.tool:1.0.0")
  end
end
