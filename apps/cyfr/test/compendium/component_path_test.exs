# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentPathTest do
  use ExUnit.Case, async: true

  alias Compendium.ComponentPath

  @local {"local", "default"}

  describe "base_prefix/1" do
    test "accepts a {org, project} tuple" do
      assert ComponentPath.base_prefix({"acme", "proj_x"}) ==
               ["components", "acme", "proj_x"]
    end

    test "accepts a map / struct exposing org_id + project_id" do
      assert ComponentPath.base_prefix(%{org_id: "acme", project_id: "proj_x"}) ==
               ["components", "acme", "proj_x"]
    end

    test "normalizes nil/empty tenant to the local/default sentinels" do
      assert ComponentPath.base_prefix({nil, nil}) == ["components", "local", "default"]
      assert ComponentPath.base_prefix({"", ""}) == ["components", "local", "default"]
      assert ComponentPath.base_prefix(%{org_id: nil, project_id: nil}) ==
               ["components", "local", "default"]
    end
  end

  describe "version_dir/5" do
    test "produces a project-scoped path" do
      assert ComponentPath.version_dir("catalyst", "local", "my-tool", "1.0.0", @local) ==
               ["components", "local", "default", "catalysts", "local", "my-tool", "1.0.0"]
    end

    test "two projects in one org resolve to distinct paths" do
      a = ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0", {"acme", "p1"})
      b = ComponentPath.version_dir("catalyst", "local", "foo", "1.0.0", {"acme", "p2"})
      refute a == b
    end
  end

  describe "wasm_path/5" do
    test "appends {type}.wasm under the tenant" do
      assert ComponentPath.wasm_path("reagent", "local", "my-tool", "1.0.0", @local) ==
               [
                 "components",
                 "local",
                 "default",
                 "reagents",
                 "local",
                 "my-tool",
                 "1.0.0",
                 "reagent.wasm"
               ]
    end
  end

  describe "file_path/6" do
    test "produces a project-scoped path to an arbitrary file" do
      assert ComponentPath.file_path("catalyst", "local", "my-tool", "1.0.0", "README.md", @local) ==
               [
                 "components",
                 "local",
                 "default",
                 "catalysts",
                 "local",
                 "my-tool",
                 "1.0.0",
                 "README.md"
               ]
    end
  end

  describe "name_dir/4" do
    test "produces a project-scoped name directory" do
      assert ComponentPath.name_dir("reagent", "local", "my-tool", @local) ==
               ["components", "local", "default", "reagents", "local", "my-tool"]
    end
  end

  describe "publisher_dir/3" do
    test "produces a project-scoped publisher directory" do
      assert ComponentPath.publisher_dir("catalyst", "local", @local) ==
               ["components", "local", "default", "catalysts", "local"]
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
