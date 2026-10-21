# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentTest do
  @moduledoc """
  Component resolution returns human-readable `{:error, binary}` results
  for malformed references, missing components, and storage faults.
  `Compendium.Providers.Shared` delegates resolution to this module.
  """

  use ExUnit.Case, async: false

  alias Compendium.Component

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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
    assert {:error, {:not_found, {:component, "reagent:local.no-such-thing:9.9.9"}} = reason} =
             Component.resolve_component(ctx, "reagent:local.no-such-thing:9.9.9")

    assert Prima.Refusal.message(reason) ==
             "Component not found: reagent:local.no-such-thing:9.9.9"
  end
end
