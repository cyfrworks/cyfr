# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PersonPermissionsTest do
  # A person's context carries the explicit permission vocabulary, never a
  # wildcard; the vocabulary covers every permission an operation declares;
  # and no production builder spells the wildcard.
  use ExUnit.Case, async: true

  alias Cyfr.Ops.Annotations
  alias Cyfr.Ops.Catalog
  alias Sanctum.Context

  defp root, do: Path.expand("../../../..", __DIR__)

  test "a person holds every permission the catalog declares, and no wildcard" do
    person = Context.person_permissions()
    refute :* in person

    declared =
      for pair <- Catalog.tool_actions(),
          [tool, action] = String.split(pair, ".", parts: 2),
          {:ok, {_module, meta}} <- [Catalog.lookup(tool)],
          permission = Annotations.permission(meta, action),
          not is_nil(permission),
          uniq: true,
          do: permission

    assert declared != []
    assert declared -- person == []

    ctx =
      Context.build(
        user_id: "usr_person",
        permissions: person,
        auth_method: :oidc,
        authenticated: true
      )

    for permission <- declared, do: assert(Context.has_permission?(ctx, permission))
  end

  test "no production builder spells the wildcard" do
    offenders =
      for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/*/lib/**/*.ex")),
          {line, n} <- path |> File.read!() |> Cyfr.Test.CodeLines.code_lines(),
          String.contains?(line, "[:*]"),
          do: "#{Path.relative_to(path, root())}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "the wildcard permission is built here:\n" <> Enum.join(offenders, "\n")
  end
end
