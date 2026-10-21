# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.DependenciesTest do
  use ExUnit.Case, async: true

  alias Prima.Manifest.Dependencies

  @ref "catalyst:local.claude:0.1.0"

  test "a manifest with no block, or a block with no static list, declares none" do
    assert Dependencies.from_manifest(nil) == {:ok, []}
    assert Dependencies.from_manifest(%{}) == {:ok, []}
    assert Dependencies.from_manifest(%{"dependencies" => %{}}) == {:ok, []}
  end

  test "an entry is a ref string or an object with a ref, in declaration order" do
    manifest = %{
      "dependencies" => %{
        "static" => [
          @ref,
          %{"ref" => "reagent:local.leaf", "optional" => true, "reason" => "why"}
        ]
      }
    }

    assert {:ok, [first, second]} = Dependencies.from_manifest(manifest)

    assert %{dependency_ref: @ref, dep_type: "catalyst", dep_name: "claude", optional: false} =
             first

    assert %{dependency_ref: "reagent:local.leaf", dep_version: nil, optional: true} = second
    assert second.reason == "why"
  end

  test "the manifest is read as decoded JSON: an atom-keyed block is no block" do
    assert Dependencies.from_manifest(%{dependencies: %{static: [@ref]}}) == {:ok, []}

    manifest = %{"dependencies" => %{"static" => [%{ref: @ref}]}}
    assert {:error, "Invalid dependency entry" <> _} = Dependencies.from_manifest(manifest)
  end

  test "a malformed block fails whole rather than declaring nothing" do
    for manifest <- [
          %{"dependencies" => [@ref]},
          %{"dependencies" => %{"static" => @ref}},
          %{"dependencies" => %{"static" => [@ref, 42]}},
          %{"dependencies" => %{"static" => ["not a ref"]}}
        ] do
      assert {:error, message} = Dependencies.from_manifest(manifest), inspect(manifest)
      assert is_binary(message)
    end
  end
end
