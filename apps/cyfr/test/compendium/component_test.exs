# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentTest do
  @moduledoc """
  Component resolution has one owner: every error class — malformed
  reference, not found, storage fault — answers a human-readable
  `{:error, binary}`, never a raise, and the MCP tool surface
  (`Compendium.MCP.Shared`) delegates here so the two can never drift.
  The duplicated MCP copy this replaces lacked the storage-fault clause
  and raised CaseClauseError in every tool resolve path.
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
