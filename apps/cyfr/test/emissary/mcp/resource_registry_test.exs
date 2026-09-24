# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceRegistryTest do
  @moduledoc """
  The resource catalogue: the advertised lists, and the scheme index the
  operation table declares. It reads nothing and authorizes nothing.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.ResourceRegistry

  describe "list_resources/0" do
    test "resources have required fields and a scheme" do
      resources = ResourceRegistry.list_resources()
      assert resources != []

      for resource <- resources do
        assert Map.has_key?(resource, "uri")
        assert Map.has_key?(resource, "name")
        assert String.contains?(resource["uri"], "://")
      end
    end

    test "keys are strings and a mime type is always present" do
      for resource <-
            ResourceRegistry.list_resources() ++ ResourceRegistry.list_resource_templates(),
          {key, _value} <- resource do
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end

      for resource <- ResourceRegistry.list_resources() do
        assert is_binary(resource["mimeType"])
      end
    end
  end

  describe "resolve/1" do
    test "every advertised scheme resolves to the operation that declares it" do
      advertised =
        for %{"uri" => uri} <- ResourceRegistry.list_resources(), do: uri

      templates =
        for %{"uriTemplate" => template} <- ResourceRegistry.list_resource_templates(),
            do: template

      assert {:ok, "component", "read_resource"} =
               ResourceRegistry.resolve("compendium://components/r:local.x:1.0.0")

      assert {:ok, "execution", "read_resource"} =
               ResourceRegistry.resolve("crucible://executions/exec_1")

      assert {:ok, "resource", "read"} = ResourceRegistry.resolve("arca://files/data/x")
      assert {:ok, "session", "read_resource"} = ResourceRegistry.resolve("sanctum://identity")

      for uri <- advertised ++ templates do
        assert {:ok, tool, action} = ResourceRegistry.resolve(uri)
        assert {:ok, {_module, meta}} = Grimoire.Catalog.lookup(tool)
        operation = Enum.find(meta.operations, &(&1.action == action))
        {:ok, scheme} = Prima.Provider.resource_scheme(uri)
        assert scheme in operation.resource_schemes
      end
    end

    test "an unknown or malformed scheme is a typed argument refusal, in today's words" do
      assert ResourceRegistry.resolve("unknown://resource/path") ==
               {:error, {:invalid_argument, "No provider found for scheme: unknown"}}

      # One spelling per scheme: the index holds the declared lowercase one.
      assert {:error, {:invalid_argument, "No provider found for scheme: ARCA"}} =
               ResourceRegistry.resolve("ARCA://files/data/x")

      for malformed <- ["invalid-uri-no-scheme", "://no-scheme", ""] do
        assert ResourceRegistry.resolve(malformed) ==
                 {:error, {:invalid_argument, "Invalid URI format: #{malformed}"}}
      end
    end
  end
end
