# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.InputValidatorTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.InputValidator

  @schema %{
    "type" => "object",
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["get", "list", "create"]
      },
      "id" => %{
        "type" => "string"
      },
      "limit" => %{
        "type" => "integer"
      },
      "input" => %{
        "type" => "object"
      },
      "tags" => %{
        "type" => "array"
      },
      "verbose" => %{
        "type" => "boolean"
      }
    },
    "required" => ["action"]
  }

  describe "validate/2" do
    test "accepts valid arguments" do
      assert :ok = InputValidator.validate(%{"action" => "get", "id" => "123"}, @schema)
    end

    test "accepts valid arguments with all types" do
      args = %{
        "action" => "list",
        "id" => "abc",
        "limit" => 10,
        "input" => %{"key" => "value"},
        "tags" => ["a", "b"],
        "verbose" => true
      }

      assert :ok = InputValidator.validate(args, @schema)
    end

    test "rejects missing required fields" do
      assert {:error, msg} = InputValidator.validate(%{"id" => "123"}, @schema)
      assert msg =~ "Missing required field: action"
    end

    test "rejects invalid enum values" do
      assert {:error, msg} = InputValidator.validate(%{"action" => "invalid"}, @schema)
      assert msg =~ "must be one of"
    end

    test "rejects wrong type for string field" do
      assert {:error, msg} = InputValidator.validate(%{"action" => "get", "id" => 123}, @schema)
      assert msg =~ "must be a string"
    end

    test "rejects wrong type for integer field" do
      assert {:error, msg} =
               InputValidator.validate(%{"action" => "get", "limit" => "ten"}, @schema)

      assert msg =~ "must be an integer"
    end

    test "rejects wrong type for object field" do
      assert {:error, msg} =
               InputValidator.validate(%{"action" => "get", "input" => "string"}, @schema)

      assert msg =~ "must be an object"
    end

    test "rejects wrong type for array field" do
      assert {:error, msg} =
               InputValidator.validate(%{"action" => "get", "tags" => "not-array"}, @schema)

      assert msg =~ "must be an array"
    end

    test "rejects wrong type for boolean field" do
      assert {:error, msg} =
               InputValidator.validate(%{"action" => "get", "verbose" => "yes"}, @schema)

      assert msg =~ "must be a boolean"
    end

    test "allows unknown properties" do
      assert :ok = InputValidator.validate(%{"action" => "get", "extra" => "field"}, @schema)
    end

    test "accepts empty schema" do
      assert :ok = InputValidator.validate(%{"anything" => "goes"}, %{})
    end

    test "accepts non-map arguments gracefully" do
      assert :ok = InputValidator.validate("not a map", @schema)
    end
  end
end
