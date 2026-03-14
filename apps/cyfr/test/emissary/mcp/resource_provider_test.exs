defmodule Emissary.MCP.ResourceProviderTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.ResourceProvider

  describe "behaviour definition" do
    test "defines resources/0 callback" do
      callbacks = ResourceProvider.behaviour_info(:callbacks)

      assert {:resources, 0} in callbacks
    end

    test "defines read/2 callback" do
      callbacks = ResourceProvider.behaviour_info(:callbacks)

      assert {:read, 2} in callbacks
    end
  end

  describe "implements?/1" do
    defmodule ValidProvider do
      @behaviour Emissary.MCP.ResourceProvider

      @impl true
      def resources do
        [
          %{
            uri: "test://config",
            name: "Test Config",
            description: "Test configuration resource"
          }
        ]
      end

      @impl true
      def read(_ctx, "test://config") do
        {:ok, %{content: %{setting: "value"}}}
      end

      def read(_ctx, _uri), do: {:error, :not_found}
    end

    defmodule PartialProvider do
      def resources, do: []
      # Missing read/2
    end

    defmodule NoResourcesProvider do
      def read(_ctx, _uri), do: {:error, :not_found}
      # Missing resources/0
    end

    test "returns true for valid provider" do
      assert ResourceProvider.implements?(ValidProvider)
    end

    test "returns false for module with only resources/0" do
      refute ResourceProvider.implements?(PartialProvider)
    end

    test "returns false for module with only read/2" do
      refute ResourceProvider.implements?(NoResourcesProvider)
    end

    test "returns false for non-existent module" do
      refute ResourceProvider.implements?(NonExistentModule)
    end
  end

  describe "provider implementation verification" do
    defmodule MockResourceProvider do
      @behaviour Emissary.MCP.ResourceProvider

      @impl true
      def resources do
        [
          %{
            uri: "mock://data",
            name: "Mock Data",
            description: "A mock resource for testing",
            mimeType: "application/json"
          }
        ]
      end

      @impl true
      def read(_ctx, "mock://data") do
        {:ok, %{content: %{key: "value"}}}
      end

      def read(_ctx, _uri), do: {:error, :not_found}
    end

    test "mock provider implements resources/0 correctly" do
      resources = MockResourceProvider.resources()

      assert is_list(resources)
      assert length(resources) == 1

      [resource] = resources
      assert resource.uri == "mock://data"
      assert resource.name == "Mock Data"
      assert is_binary(resource.description)
    end

    test "mock provider implements read/2 correctly" do
      ctx = Sanctum.Context.local()

      assert {:ok, result} = MockResourceProvider.read(ctx, "mock://data")
      assert result.content.key == "value"
    end

    test "mock provider returns error for unknown URI" do
      ctx = Sanctum.Context.local()

      assert {:error, :not_found} = MockResourceProvider.read(ctx, "mock://unknown")
    end
  end

  describe "resource definition structure" do
    test "required fields are uri and name" do
      valid_resource = %{
        uri: "service://path",
        name: "Resource Name"
      }

      assert Map.has_key?(valid_resource, :uri)
      assert Map.has_key?(valid_resource, :name)
    end

    test "optional fields include description and mimeType" do
      full_resource = %{
        uri: "service://path",
        name: "Resource Name",
        description: "Description of the resource",
        mimeType: "application/json"
      }

      assert Map.has_key?(full_resource, :description)
      assert Map.has_key?(full_resource, :mimeType)
    end
  end
end
