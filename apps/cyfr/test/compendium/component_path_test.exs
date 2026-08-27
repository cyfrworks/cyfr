# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPathTest do
  use ExUnit.Case, async: true

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
      assert Arca.Storage.seed_prefix("components") == ["seed", "components"]
      assert "components" in Arca.Storage.seed_roots()
    end
  end

  describe "locate/1 — the overlay's unit grammar" do
    test "the unit is exactly the version directory, sentinel'd by the manifest" do
      vd = ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0")

      assert ComponentPath.locate(vd) == {:dir, vd, ComponentPath.manifest_name()}
      assert ComponentPath.locate(vd ++ ["src", "lib.rs"]) == {:dir, vd, "cyfr-manifest.json"}

      assert ComponentPath.locate(ComponentPath.name_dir("catalyst", "local", "my-tool")) ==
               :above_unit

      assert ComponentPath.locate(ComponentPath.base_prefix()) == :above_unit
    end

    test "every path helper lands at or below the unit its own arguments name" do
      # The grammar and the constructors can never disagree about where
      # the unit sits.
      vd = ComponentPath.version_dir("tincture", "acme", "widget", "2.1.0")

      for path <- [
            vd,
            ComponentPath.wasm_path("tincture", "acme", "widget", "2.1.0"),
            ComponentPath.file_path("tincture", "acme", "widget", "2.1.0", "index.html"),
            ComponentPath.manifest_path("tincture", "acme", "widget", "2.1.0")
          ] do
        assert {:dir, ^vd, _sentinel} = ComponentPath.locate(path)
      end
    end
  end

  describe "type_plural/1" do
    test "is the one pluralization rule the compile-time roster follows" do
      assert ComponentPath.type_plurals() ==
               Enum.map(Sanctum.ComponentRef.valid_types(), &ComponentPath.type_plural/1)
    end
  end

  describe "default_publisher/0" do
    test "is the local namespace, and local_publisher?/1 agrees" do
      assert ComponentPath.default_publisher() == "local"
      assert ComponentPath.local_publisher?(ComponentPath.default_publisher())
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
