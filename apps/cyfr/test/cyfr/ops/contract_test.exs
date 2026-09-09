# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ContractTest do
  use ExUnit.Case, async: true

  alias Cyfr.Ops.Contract

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
      assert :ok = Contract.validate(%{"action" => "get", "id" => "123"}, @schema)
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

      assert :ok = Contract.validate(args, @schema)
    end

    test "rejects missing required fields" do
      assert {:error, msg} = Contract.validate(%{"id" => "123"}, @schema)
      assert msg =~ "Missing required field: action"
    end

    test "rejects invalid enum values" do
      assert {:error, msg} = Contract.validate(%{"action" => "invalid"}, @schema)
      assert msg =~ "must be one of"
    end

    test "rejects wrong type for string field" do
      assert {:error, msg} = Contract.validate(%{"action" => "get", "id" => 123}, @schema)
      assert msg =~ "must be a string"
    end

    test "rejects wrong type for integer field" do
      assert {:error, msg} =
               Contract.validate(%{"action" => "get", "limit" => "ten"}, @schema)

      assert msg =~ "must be an integer"
    end

    test "rejects wrong type for object field" do
      assert {:error, msg} =
               Contract.validate(%{"action" => "get", "input" => "string"}, @schema)

      assert msg =~ "must be an object"
    end

    test "rejects wrong type for array field" do
      assert {:error, msg} =
               Contract.validate(%{"action" => "get", "tags" => "not-array"}, @schema)

      assert msg =~ "must be an array"
    end

    test "rejects wrong type for boolean field" do
      assert {:error, msg} =
               Contract.validate(%{"action" => "get", "verbose" => "yes"}, @schema)

      assert msg =~ "must be a boolean"
    end

    test "allows unknown properties" do
      assert :ok = Contract.validate(%{"action" => "get", "extra" => "field"}, @schema)
    end

    test "accepts empty schema" do
      assert :ok = Contract.validate(%{"anything" => "goes"}, %{})
    end

    test "rejects non-map arguments" do
      # The dispatcher reads `arguments["action"]` immediately after this call,
      # and Access raises on a list — so letting a non-object through here turns
      # a client mistake into a 500 rather than a JSON-RPC error.
      assert {:error, msg} = Contract.validate("not a map", @schema)
      assert msg =~ "must be an object"
      assert msg =~ "string"

      assert {:error, list_msg} = Contract.validate([1, 2, 3], @schema)
      assert list_msg =~ "array"

      assert {:error, _} = Contract.validate(42, @schema)
      assert {:error, _} = Contract.validate(true, @schema)
    end

    test "rejects non-map arguments even when the schema is unusable" do
      assert {:error, msg} = Contract.validate([1, 2, 3], "not a schema")
      assert msg =~ "must be an object"
    end
  end

  describe "string constraints" do
    test "enforces declared minLength, maxLength and pattern" do
      schema = %{
        "properties" => %{
          "slug" => %{
            "type" => "string",
            "minLength" => 2,
            "maxLength" => 5,
            "pattern" => "^[a-z]+$"
          }
        }
      }

      assert :ok = Contract.validate(%{"slug" => "abc"}, schema)
      assert {:error, msg} = Contract.validate(%{"slug" => "a"}, schema)
      assert msg =~ "at least 2"
      assert {:error, msg} = Contract.validate(%{"slug" => "abcdef"}, schema)
      assert msg =~ "at most 5"
      assert {:error, msg} = Contract.validate(%{"slug" => "ABC"}, schema)
      assert msg =~ "pattern"
    end

    test "an invalid pattern in the schema refuses instead of silently passing" do
      # Invalid schema regexes must fail validation.
      schema = %{"properties" => %{"x" => %{"type" => "string", "pattern" => "["}}}
      assert {:error, message} = Contract.validate(%{"x" => "anything"}, schema)
      assert message =~ "invalid pattern"
    end
  end

  describe "nested objects" do
    test "a nested object's own required and properties bind" do
      schema = %{
        "properties" => %{
          "config" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"count" => %{"type" => "integer"}}
          }
        }
      }

      assert :ok = Contract.validate(%{"config" => %{"name" => "x", "count" => 1}}, schema)

      assert {:error, msg} = Contract.validate(%{"config" => %{"count" => 1}}, schema)
      assert msg =~ "Missing required field: name"

      assert {:error, msg} =
               Contract.validate(%{"config" => %{"name" => "x", "count" => "1"}}, schema)

      assert msg =~ "must be an integer"
    end
  end
end
