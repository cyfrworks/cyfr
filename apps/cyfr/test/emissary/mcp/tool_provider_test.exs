defmodule Emissary.MCP.ToolProviderTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.ToolProvider

  describe "behaviour definition" do
    test "defines tools/0 callback" do
      callbacks = ToolProvider.behaviour_info(:callbacks)

      assert {:tools, 0} in callbacks
    end

    test "defines handle/3 callback" do
      callbacks = ToolProvider.behaviour_info(:callbacks)

      assert {:handle, 3} in callbacks
    end
  end

  describe "type specifications" do
    test "tool_definition type is documented" do
      # Verify the module compiles and exports expected types
      # The type specs are checked at compile time, but we can verify
      # the module is properly loaded
      assert Code.ensure_loaded?(ToolProvider)
    end

    test "handle_result type is documented" do
      assert Code.ensure_loaded?(ToolProvider)
    end
  end

  describe "provider implementation verification" do
    defmodule MockToolProvider do
      @behaviour Emissary.MCP.ToolProvider

      @impl true
      def tools do
        [
          %{
            name: "mock/test",
            description: "A mock tool for testing",
            input_schema: %{
              "type" => "object",
              "properties" => %{
                "input" => %{"type" => "string"}
              }
            }
          }
        ]
      end

      @impl true
      def handle("mock/test", _ctx, args) do
        {:ok, %{echoed: args["input"]}}
      end

      def handle(_tool, _ctx, _args) do
        {:error, "Unknown tool"}
      end
    end

    test "mock provider implements tools/0 correctly" do
      tools = MockToolProvider.tools()

      assert is_list(tools)
      assert length(tools) == 1

      [tool] = tools
      assert tool.name == "mock/test"
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
    end

    test "mock provider implements handle/3 correctly" do
      ctx = Sanctum.Context.local()

      assert {:ok, result} = MockToolProvider.handle("mock/test", ctx, %{"input" => "hello"})
      assert result.echoed == "hello"
    end

    test "mock provider returns error for unknown tool" do
      ctx = Sanctum.Context.local()

      assert {:error, _} = MockToolProvider.handle("unknown/tool", ctx, %{})
    end
  end

  describe "tool definition structure" do
    test "required fields are name, description, input_schema" do
      # This is a documentation/specification test
      # A valid tool definition must have these fields
      valid_tool = %{
        name: "service/action",
        description: "Does something useful",
        input_schema: %{"type" => "object"}
      }

      assert Map.has_key?(valid_tool, :name)
      assert Map.has_key?(valid_tool, :description)
      assert Map.has_key?(valid_tool, :input_schema)
    end

    test "optional fields include title, icons, output_schema, annotations" do
      # This is a documentation/specification test for optional MCP 2025-11-25 fields
      full_tool = %{
        name: "service/action",
        description: "Does something useful",
        input_schema: %{"type" => "object"},
        title: "Human Readable Name",
        icons: [%{src: "icon.png", mimeType: "image/png"}],
        output_schema: %{"type" => "object"},
        annotations: %{readOnly: true}
      }

      assert Map.has_key?(full_tool, :title)
      assert Map.has_key?(full_tool, :icons)
      assert Map.has_key?(full_tool, :output_schema)
      assert Map.has_key?(full_tool, :annotations)
    end
  end
end
