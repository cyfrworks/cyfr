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

  test "every permission an action annotation gates is a known permission" do
    known =
      Sanctum.Atoms.known_permissions()
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    gated = annotation_permissions()

    assert MapSet.size(gated) > 0

    for perm <- gated do
      assert perm in known, "gated permission #{inspect(perm)} not in Sanctum.Atoms"
    end
  end

  test "every known permission but the wildcard gates something" do
    gated = MapSet.union(annotation_permissions(), checked_permissions())

    for name <- Sanctum.Atoms.known_permissions() -- ["*"] do
      assert String.to_atom(name) in gated,
             "#{name} is granted but gates no action annotation and no permission check"
    end
  end

  defp annotation_permissions do
    for module <- Application.fetch_env!(:cyfr, :tool_providers),
        Code.ensure_loaded?(module),
        tool <- module.tools(),
        {_verb, annotation} <- get_in(tool, [Access.key(:annotations, %{}), :actions]) || %{},
        perm = Map.get(annotation, :permission),
        not is_nil(perm),
        into: MapSet.new() do
      perm
    end
  end

  # The permissions named literally at a `require_permission`,
  # `has_permission?` or `authorize` call anywhere in the umbrella's code.
  defp checked_permissions do
    root = Path.expand("../../../..", __DIR__)

    for lib <- Cyfr.Test.SourceTree.app_libs(root),
        file <- Cyfr.Test.SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
        [_, perm] <-
          Regex.scan(
            ~r/(?:require_permission|has_permission\?|authorize)\(\s*\w+,\s*:(\w+)/,
            File.read!(file)
          ),
        into: MapSet.new() do
      String.to_atom(perm)
    end
  end
end
