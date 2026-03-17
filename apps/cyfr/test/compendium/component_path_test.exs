defmodule Compendium.ComponentPathTest do
  use ExUnit.Case, async: true

  alias Compendium.ComponentPath

  describe "base_prefix/1" do
    test "Core mode (nil) returns flat prefix" do
      assert ComponentPath.base_prefix(nil) == ["components"]
    end

    test "Arx mode returns org-scoped prefix" do
      assert ComponentPath.base_prefix("org_abc") == ["components", "org_abc"]
    end
  end

  describe "version_dir/5" do
    test "Core mode produces flat path" do
      assert ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0") ==
               ["components", "catalysts", "local", "my-tool", "1.0.0"]
    end

    test "Arx mode produces org-scoped path" do
      assert ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0", "org_abc") ==
               ["components", "org_abc", "catalysts", "local", "my-tool", "1.0.0"]
    end

    test "nil org_id produces same as Core" do
      assert ComponentPath.version_dir("reagent", "cyfr", "r1", "0.1.0", nil) ==
               ComponentPath.version_dir("reagent", "cyfr", "r1", "0.1.0")
    end
  end

  describe "wasm_path/5" do
    test "Core mode appends {type}.wasm" do
      assert ComponentPath.wasm_path("reagent", "local", "my-tool", "1.0.0") ==
               ["components", "reagents", "local", "my-tool", "1.0.0", "reagent.wasm"]
    end

    test "Arx mode appends {type}.wasm under org" do
      assert ComponentPath.wasm_path("catalyst", "local", "my-tool", "1.0.0", "org_abc") ==
               [
                 "components",
                 "org_abc",
                 "catalysts",
                 "local",
                 "my-tool",
                 "1.0.0",
                 "catalyst.wasm"
               ]
    end
  end

  describe "file_path/6" do
    test "Core mode produces path to arbitrary file" do
      assert ComponentPath.file_path("catalyst", "local", "my-tool", "1.0.0", "README.md") ==
               ["components", "catalysts", "local", "my-tool", "1.0.0", "README.md"]
    end

    test "Arx mode produces org-scoped path to arbitrary file" do
      assert ComponentPath.file_path(
               "catalyst",
               "local",
               "my-tool",
               "1.0.0",
               "README.md",
               "org_abc"
             ) ==
               ["components", "org_abc", "catalysts", "local", "my-tool", "1.0.0", "README.md"]
    end
  end

  describe "name_dir/4" do
    test "Core mode" do
      assert ComponentPath.name_dir("reagent", "local", "my-tool") ==
               ["components", "reagents", "local", "my-tool"]
    end

    test "Arx mode" do
      assert ComponentPath.name_dir("reagent", "local", "my-tool", "org_abc") ==
               ["components", "org_abc", "reagents", "local", "my-tool"]
    end
  end

  describe "publisher_dir/3" do
    test "Core mode" do
      assert ComponentPath.publisher_dir("catalyst", "local") ==
               ["components", "catalysts", "local"]
    end

    test "Arx mode" do
      assert ComponentPath.publisher_dir("catalyst", "local", "org_abc") ==
               ["components", "org_abc", "catalysts", "local"]
    end
  end

  describe "type_plurals/0" do
    test "returns known type plurals" do
      assert "catalysts" in ComponentPath.type_plurals()
      assert "reagents" in ComponentPath.type_plurals()
      assert "formulas" in ComponentPath.type_plurals()
    end
  end
end
