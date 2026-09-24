# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.ResourcesTest do
  @moduledoc """
  The resource index: the advertised lists, and the scheme index the
  operation table declares, held in the term the table was written with.
  It reads nothing and authorizes nothing.
  """
  use ExUnit.Case, async: true

  alias Grimoire.Resources

  describe "list_resources/0" do
    test "resources have required fields and a scheme" do
      resources = Resources.list_resources()
      assert resources != []

      for resource <- resources do
        assert Map.has_key?(resource, "uri")
        assert Map.has_key?(resource, "name")
        assert String.contains?(resource["uri"], "://")
      end
    end

    test "is the term the table was written with" do
      assert Grimoire.resources().resources == Resources.list_resources()
      assert Grimoire.resources().templates == Resources.list_resource_templates()
    end

    test "keys are strings and a mime type is always present" do
      for resource <-
            Resources.list_resources() ++ Resources.list_resource_templates(),
          {key, _value} <- resource do
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end

      for resource <- Resources.list_resources() do
        assert is_binary(resource["mimeType"])
      end
    end
  end

  describe "resolve/1" do
    test "every advertised scheme resolves to the operation that declares it" do
      advertised =
        for %{"uri" => uri} <- Resources.list_resources(), do: uri

      templates =
        for %{"uriTemplate" => template} <- Resources.list_resource_templates(),
            do: template

      assert {:ok, "component", "read_resource"} =
               Resources.resolve("compendium://components/r:local.x:1.0.0")

      assert {:ok, "execution", "read_resource"} =
               Resources.resolve("crucible://executions/exec_1")

      assert {:ok, "resource", "read"} = Resources.resolve("arca://files/data/x")
      assert {:ok, "session", "read_resource"} = Resources.resolve("sanctum://identity")

      for uri <- advertised ++ templates do
        assert {:ok, tool, action} = Resources.resolve(uri)
        assert {:ok, {_module, meta}} = Grimoire.lookup(tool)
        operation = Enum.find(meta.operations, &(&1.action == action))
        {:ok, scheme} = Prima.Provider.resource_scheme(uri)
        assert scheme in operation.resource_schemes
      end
    end

    test "an unknown or malformed scheme is a typed argument refusal, in today's words" do
      assert Resources.resolve("unknown://resource/path") ==
               {:error, {:invalid_argument, "No provider found for scheme: unknown"}}

      # One spelling per scheme: the index holds the declared lowercase one.
      assert {:error, {:invalid_argument, "No provider found for scheme: ARCA"}} =
               Resources.resolve("ARCA://files/data/x")

      for malformed <- ["invalid-uri-no-scheme", "://no-scheme", ""] do
        assert Resources.resolve(malformed) ==
                 {:error, {:invalid_argument, "Invalid URI format: #{malformed}"}}
      end
    end
  end
end
