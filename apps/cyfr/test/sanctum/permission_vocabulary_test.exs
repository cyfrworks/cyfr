# SPDX-License-Identifier: Apache-2.0
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

  test "a key may hold every permission but the wildcard, and its presets hold only those" do
    keyed = for {scope, _what} <- Sanctum.ApiKey.permissions(), do: scope

    assert Enum.sort(keyed) ==
             Enum.sort(Enum.map(Sanctum.Atoms.person_permissions(), &Atom.to_string/1))

    for {_name, scopes} <- Sanctum.ApiKey.presets(), scope <- scopes do
      assert scope in keyed, "preset scope #{inspect(scope)} is no key permission"
    end
  end

  test "every permission an action annotation gates is a known permission" do
    known = MapSet.new(Sanctum.Atoms.known_permissions())
    gated = annotation_permissions()

    assert MapSet.size(gated) > 0

    for perm <- gated do
      assert perm in known, "gated permission #{inspect(perm)} not in Sanctum.Atoms"
    end
  end

  test "every known permission but the wildcard gates something" do
    gated = MapSet.union(annotation_permissions(), checked_permissions())

    for name <- Sanctum.Atoms.known_permissions() -- ["*"] do
      assert name in gated,
             "#{name} is granted but gates no action annotation and no permission check"
    end
  end

  defp annotation_permissions do
    for module <- Application.fetch_env!(:sanctum, :tool_providers),
        Code.ensure_loaded?(module),
        tool <- module.tools(),
        {_verb, annotation} <- get_in(tool, [Access.key(:annotations, %{}), :actions]) || %{},
        perm = Map.get(annotation, :permission),
        not is_nil(perm),
        into: MapSet.new() do
      Atom.to_string(perm)
    end
  end

  # The permissions named literally at a `require_permission`,
  # `has_permission?` or `authorize` call anywhere in the umbrella's code.
  defp checked_permissions do
    root = Path.expand("../../../..", __DIR__)

    for lib <- Prima.Test.SourceTree.app_libs(root),
        file <- Prima.Test.SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
        [_, perm] <-
          Regex.scan(
            ~r/(?:require_permission|has_permission\?|authorize)\(\s*\w+,\s*:(\w+)/,
            File.read!(file)
          ),
        into: MapSet.new() do
      perm
    end
  end
end
