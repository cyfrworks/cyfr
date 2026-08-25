# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPathTest do
  use ExUnit.Case, async: true

  alias Compendium.Bundle
  alias Compendium.ComponentId
  alias Compendium.ComponentPath

  describe "base_prefix/0" do
    test "is tenant-relative — the context handed to Arca names the athanor" do
      assert ComponentPath.base_prefix() == ["components"]
    end
  end

  describe "version_dir/4" do
    test "produces a tenant-relative version path" do
      assert ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0") ==
               ["components", "catalysts", "local", "my-tool", "1.0.0"]
    end
  end

  describe "wasm_path/4" do
    test "appends {type}.wasm to the version directory" do
      assert ComponentPath.wasm_path("reagent", "local", "my-tool", "1.0.0") ==
               ["components", "reagents", "local", "my-tool", "1.0.0", "reagent.wasm"]
    end
  end

  describe "file_path/5" do
    test "produces a tenant-relative path to an arbitrary file" do
      assert ComponentPath.file_path("catalyst", "local", "my-tool", "1.0.0", "README.md") ==
               ["components", "catalysts", "local", "my-tool", "1.0.0", "README.md"]
    end
  end

  describe "name_dir/3" do
    test "produces a tenant-relative name directory" do
      assert ComponentPath.name_dir("reagent", "local", "my-tool") ==
               ["components", "reagents", "local", "my-tool"]
    end
  end

  describe "publisher_dir/2" do
    test "produces a tenant-relative publisher directory" do
      assert ComponentPath.publisher_dir("catalyst", "local") ==
               ["components", "catalysts", "local"]
    end
  end

  describe "the seed bundle" do
    test "lives under the reserved seed root, outside every athanor's tree" do
      assert Bundle.bundle_prefix() == ["seed", "components"]
      assert Map.has_key?(Arca.Storage.seed_roots(), "components")
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
          ComponentPath.version_dir("catalyst", pub, "foo", "1.0.0")
        end

      assert Enum.uniq(paths) |> length() == 1
    end
  end

  describe "publisher normalization agrees with ComponentId" do
    test "an absent publisher resolves to the same id AND the same path as an explicit local" do
      # The id chokepoint and the path chokepoint must normalize publisher
      # identically, or a nil-publisher component would be addressed by one id
      # and stored at a different path.
      assert ComponentId.compute("foo", "1.0.0", nil, "catalyst", "ath_a") ==
               ComponentId.compute("foo", "1.0.0", "local", "catalyst", "ath_a")

      assert ComponentPath.version_dir("catalyst", nil, "foo", "1.0.0") ==
               ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0")
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
