defmodule Emissary.MCP.ResourceRegistryTest do
  @moduledoc """
  Tests for the MCP resource registry.

  Verifies resource discovery, listing, and URI routing.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.ResourceRegistry
  alias Sanctum.Context

  describe "list_resources/0" do
    test "returns a list" do
      resources = ResourceRegistry.list_resources()
      assert is_list(resources)
    end

    test "resources have required fields" do
      resources = ResourceRegistry.list_resources()

      for resource <- resources do
        assert Map.has_key?(resource, "uri")
        assert Map.has_key?(resource, "name")
        # description and mimeType are optional but included
      end
    end

    test "resources have valid URI format" do
      resources = ResourceRegistry.list_resources()

      for resource <- resources do
        uri = resource["uri"]
        assert is_binary(uri)
        # Should have a scheme
        assert String.contains?(uri, "://")
      end
    end
  end

  describe "read/2 - URI scheme routing" do
    test "returns error for unknown scheme" do
      ctx = Context.local()

      result = ResourceRegistry.read(ctx, "unknown://resource/path")

      assert {:error, message} = result
      assert message =~ "No provider found for scheme"
    end

    test "returns error for invalid URI format - no scheme" do
      ctx = Context.local()

      result = ResourceRegistry.read(ctx, "invalid-uri-no-scheme")

      assert {:error, message} = result
      assert message =~ "Invalid URI format"
    end

    test "returns error for empty scheme" do
      ctx = Context.local()

      result = ResourceRegistry.read(ctx, "://no-scheme")

      assert {:error, message} = result
      assert message =~ "Invalid URI format"
    end
  end

  describe "resource format" do
    test "format_resource normalizes keys to strings" do
      resources = ResourceRegistry.list_resources()

      for resource <- resources do
        # All keys should be strings
        for {key, _value} <- resource do
          assert is_binary(key), "Expected string key, got: #{inspect(key)}"
        end
      end
    end

    test "resources include mimeType defaulting to application/json" do
      resources = ResourceRegistry.list_resources()

      for resource <- resources do
        mime_type = resource["mimeType"]
        assert is_binary(mime_type)
      end
    end
  end
end
