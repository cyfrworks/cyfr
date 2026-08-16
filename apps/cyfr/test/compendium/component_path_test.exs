# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPathTest do
  use ExUnit.Case, async: true

  alias Compendium.Bundle
  alias Compendium.ComponentId
  alias Compendium.ComponentPath

  @athanor "ath_a"

  describe "base_prefix/1" do
    test "accepts a bare athanor id" do
      assert ComponentPath.base_prefix("ath_x") == ["components", "ath_x"]
    end

    test "accepts a map / struct exposing athanor_id" do
      assert ComponentPath.base_prefix(%{athanor_id: "ath_x"}) == ["components", "ath_x"]
      assert ComponentPath.base_prefix(Sanctum.TestContext.local()) == ["components", "ath_test"]
    end

    test "raises on an unresolved athanor — same fail-closed guard as Arca.Storage" do
      assert_raise ArgumentError, ~r/resolved athanor_id is required/, fn ->
        ComponentPath.base_prefix(nil)
      end

      assert_raise ArgumentError, ~r/resolved athanor_id is required/, fn ->
        ComponentPath.base_prefix("")
      end

      assert_raise ArgumentError, ~r/resolved athanor_id is required/, fn ->
        ComponentPath.base_prefix(%{athanor_id: nil})
      end
    end
  end

  describe "version_dir/5" do
    test "produces an athanor-scoped path" do
      assert ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0", @athanor) ==
               ["components", "ath_a", "catalysts", "local", "my-tool", "1.0.0"]
    end

    test "two athanors resolve to distinct paths" do
      a = ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0", "ath_a")
      b = ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0", "ath_b")
      refute a == b
    end
  end

  describe "wasm_path/5" do
    test "appends {type}.wasm under the athanor" do
      assert ComponentPath.wasm_path("reagent", "local", "my-tool", "1.0.0", @athanor) ==
               ["components", "ath_a", "reagents", "local", "my-tool", "1.0.0", "reagent.wasm"]
    end
  end

  describe "file_path/6" do
    test "produces an athanor-scoped path to an arbitrary file" do
      assert ComponentPath.file_path("catalyst", "local", "my-tool", "1.0.0", "README.md", @athanor) ==
               ["components", "ath_a", "catalysts", "local", "my-tool", "1.0.0", "README.md"]
    end
  end

  describe "name_dir/4" do
    test "produces an athanor-scoped name directory" do
      assert ComponentPath.name_dir("reagent", "local", "my-tool", @athanor) ==
               ["components", "ath_a", "reagents", "local", "my-tool"]
    end
  end

  describe "publisher_dir/3" do
    test "produces an athanor-scoped publisher directory" do
      assert ComponentPath.publisher_dir("catalyst", "local", @athanor) ==
               ["components", "ath_a", "catalysts", "local"]
    end
  end

  describe "the seed bundle" do
    test "lives beside the athanor trees under a segment no athanor can own" do
      assert Bundle.bundle_prefix() == ["components", "_bundle"]
      refute Sanctum.ComponentRef.valid_personal_slug?(Bundle.segment())
    end
  end

  describe "normalize_publisher/1" do
    test "collapses nil/empty to the local namespace" do
      assert ComponentPath.normalize_publisher(nil) == "local"
      assert ComponentPath.normalize_publisher("") == "local"
    end

    test "passes a concrete publisher through unchanged" do
      assert ComponentPath.normalize_publisher("acme") == "acme"
    end

    test "nil/empty/local publisher all yield the same version path" do
      paths =
        for pub <- [nil, "", "local"] do
          ComponentPath.version_dir("catalyst", pub, "foo", "1.0.0", @athanor)
        end

      assert Enum.uniq(paths) |> length() == 1
    end
  end

  describe "publisher normalization agrees with ComponentId" do
    test "an absent publisher resolves to the same id AND the same path as an explicit local" do
      # The id chokepoint and the path chokepoint must normalize publisher
      # identically, or a nil-publisher component would be addressed by one id
      # and stored at a different path.
      assert ComponentId.compute("foo", "1.0.0", nil, "catalyst", @athanor) ==
               ComponentId.compute("foo", "1.0.0", "local", "catalyst", @athanor)

      assert ComponentPath.version_dir("catalyst", nil, "foo", "1.0.0", @athanor) ==
               ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0", @athanor)
    end
  end

  describe "type_plurals/0" do
    test "returns known type plurals" do
      assert "catalysts" in ComponentPath.type_plurals()
      assert "reagents" in ComponentPath.type_plurals()
      assert "formulas" in ComponentPath.type_plurals()
      assert "tinctures" in ComponentPath.type_plurals()
    end
  end
end
