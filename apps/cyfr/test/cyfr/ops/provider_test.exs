# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ProviderTest do
  use ExUnit.Case, async: true

  alias Cyfr.Ops.{Arg, Operation, Provider}

  defmodule MockToolProvider do
    @behaviour Cyfr.Ops.Provider

    @impl true
    def service, do: "mock"

    @impl true
    def tools do
      [
        Operation.tool(
          [
            Operation.new("mock", "echo", "Echo an input", [Arg.new("input", :string)],
              kind: :read,
              planes: [:external]
            )
          ],
          description: "A mock tool for testing"
        )
      ]
    end

    @impl true
    def handle("mock", _ctx, %{"action" => "echo"} = args),
      do: {:ok, %{echoed: args["input"]}}

    def handle(_tool, _ctx, _args), do: {:error, "Unknown tool"}
  end

  test "the shared behaviour defines provider callbacks" do
    callbacks = Provider.behaviour_info(:callbacks)
    assert {:service, 0} in callbacks
    assert {:tools, 0} in callbacks
    assert {:handle, 3} in callbacks
  end

  test "providers expose canonical operations and derived discovery and policy" do
    [tool] = MockToolProvider.tools()
    assert tool.name == "mock"
    assert [%Operation{action: "echo"}] = tool.operations
    assert tool.input_schema == Operation.schema(tool.operations)
    assert Provider.action_enum(tool) == ["echo"]

    assert tool.annotations.actions["echo"] == %{
             kind: :read,
             planes: [:external],
             auth: :required
           }

    assert {:ok, %{"action" => "echo", "input" => "hello"}} =
             Operation.cast(tool, %{"action" => "echo", "input" => "hello"})
  end

  test "a provider handles its declared operation with an opaque context" do
    assert {:ok, %{echoed: "hello"}} =
             MockToolProvider.handle("mock", make_ref(), %{"action" => "echo", "input" => "hello"})

    assert {:error, _} = MockToolProvider.handle("unknown", make_ref(), %{})
  end

  test "every loadable configured provider implements the moved behaviour" do
    for module <- Cyfr.Ops.Catalog.available_providers() do
      assert function_exported?(module, :service, 0)
      assert function_exported?(module, :tools, 0)
      assert function_exported?(module, :handle, 3)

      for tool <- module.tools() do
        assert is_list(tool.operations) and tool.operations != []
        Enum.each(tool.operations, &Operation.validate!/1)
        assert tool.input_schema == Operation.schema(tool.operations)
      end
    end
  end

  test "optional tool metadata accompanies derived annotations" do
    [definition] = MockToolProvider.tools()

    tool =
      Operation.tool(definition.operations,
        title: "Human Readable Name",
        icons: [%{src: "icon.png", mimeType: "image/png"}],
        output_schema: %{"type" => "object"}
      )

    assert tool.title == "Human Readable Name"
    assert tool.icons == [%{src: "icon.png", mimeType: "image/png"}]
    assert tool.output_schema == %{"type" => "object"}
    assert tool.annotations == definition.annotations
  end

  test "thread consent restarts accept committed integer revisions and absent result metadata" do
    tool = Emissary.MCP.ThreadTool.definition()

    for metadata <- [
          %{},
          %{"profile_id" => nil, "revision" => nil},
          %{"profile_id" => "profile", "revision" => 2}
        ] do
      args = Map.merge(%{"action" => "restart_for_consent", "thread" => "thread"}, metadata)
      assert {:ok, ^args} = Operation.cast(tool, args)
    end

    assert {:error, {:invalid_argument, _}} =
             Operation.cast(tool, %{
               "action" => "restart_for_consent",
               "thread" => "thread",
               "revision" => "2"
             })
  end
end
