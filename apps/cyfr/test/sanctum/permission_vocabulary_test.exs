# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PermissionVocabularyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the permission vocabulary to one list.

  A scope granted anywhere but missing from `Sanctum.Atoms` degrades
  silently: `safe_to_permission_atom/1` returns the string and
  `context_from_metadata/1` filters it out, so the key loses the scope
  without an error. These assertions turn that silence into a test failure.
  """

  test "every API-key default and ceiling scope is a known permission" do
    known = Sanctum.Atoms.known_permissions() |> MapSet.new()

    for {_type, scopes} <- Sanctum.ApiKey.type_defaults(),
        scope <- scopes do
      assert scope in known, "default scope #{inspect(scope)} not in Sanctum.Atoms"
    end

    for {_type, scopes} <- Sanctum.ApiKey.type_ceilings(),
        scope <- scopes do
      assert scope in known, "ceiling scope #{inspect(scope)} not in Sanctum.Atoms"
    end
  end

  test "every permission the tool-visibility map gates is a known permission" do
    known =
      Sanctum.Atoms.known_permissions()
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    gated =
      Emissary.MCP.ToolVisibility.action_permissions()
      |> Map.values()
      |> MapSet.new()

    for perm <- gated do
      assert perm in known, "gated permission #{inspect(perm)} not in Sanctum.Atoms"
    end
  end
end
