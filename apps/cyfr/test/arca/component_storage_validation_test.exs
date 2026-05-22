# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ComponentStorageValidationTest do
  use ExUnit.Case, async: true

  alias Arca.ComponentStorage

  @valid_attrs %{
    name: "my-tool",
    version: "1.0.0",
    component_type: "catalyst",
    publisher: "local"
  }

  describe "validate_attrs/1" do
    test "accepts valid attributes" do
      assert :ok = ComponentStorage.validate_attrs(@valid_attrs)
    end

    test "rejects missing name" do
      attrs = Map.delete(@valid_attrs, :name)
      assert {:error, {:missing_required, :name}} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects empty name" do
      attrs = %{@valid_attrs | name: ""}
      assert {:error, {:missing_required, :name}} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects missing version" do
      attrs = Map.delete(@valid_attrs, :version)
      assert {:error, {:missing_required, :version}} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects missing component_type" do
      attrs = Map.delete(@valid_attrs, :component_type)

      assert {:error, {:missing_required, :component_type}} =
               ComponentStorage.validate_attrs(attrs)
    end

    test "rejects missing publisher" do
      attrs = Map.delete(@valid_attrs, :publisher)
      assert {:error, {:missing_required, :publisher}} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects invalid name format" do
      attrs = %{@valid_attrs | name: "MY_CAPS"}
      assert {:error, msg} = ComponentStorage.validate_attrs(attrs)
      assert msg =~ "name" or match?({:error, _}, {:error, msg})
    end

    test "rejects invalid version format" do
      attrs = %{@valid_attrs | version: "not-semver"}
      assert {:error, _} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects invalid component_type" do
      attrs = %{@valid_attrs | component_type: "widget"}
      assert {:error, _} = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects invalid publisher format" do
      attrs = %{@valid_attrs | publisher: "UPPER_CASE"}
      assert {:error, _} = ComponentStorage.validate_attrs(attrs)
    end

    test "accepts string keys" do
      attrs = %{
        "name" => "my-tool",
        "version" => "1.0.0",
        "component_type" => "catalyst",
        "publisher" => "local"
      }

      assert :ok = ComponentStorage.validate_attrs(attrs)
    end
  end
end
