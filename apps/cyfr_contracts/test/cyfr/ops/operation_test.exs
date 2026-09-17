# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.OperationTest do
  use ExUnit.Case, async: true
  alias Cyfr.Ops.{Arg, Operation}

  defp tool do
    Operation.tool(
      [
        Operation.new(
          "sample",
          "create",
          "Create a sample",
          [Arg.new("name", :string, required: true)],
          kind: :write,
          planes: [:external],
          permission: :execute
        ),
        Operation.new("sample", "list", "List samples", [Arg.new("limit", :integer, min: 0)],
          kind: :read,
          planes: [:external, :in_chain],
          recovery: :replay_safe
        )
      ],
      description: "Manage samples",
      title: "Samples"
    )
  end

  test "each action has its own required fields and closed argument set" do
    definition = tool()
    assert {:ok, %{"action" => "list"}} = Operation.cast(definition, %{"action" => "list"})

    assert {:ok, %{"action" => "list", "limit" => 0}} =
             Operation.cast(definition, %{"action" => "list", "limit" => 0})

    assert {:error, {:invalid_argument, _}} = Operation.cast(definition, %{"action" => "create"})

    assert {:error, {:invalid_argument, _}} =
             Operation.cast(definition, %{"action" => "list", "name" => "extra"})

    assert {:error, :action_missing} = Operation.cast(definition, %{})
    assert {:error, {:invalid_argument, _}} = Operation.cast(definition, %{"action" => nil})

    assert {:error, {:unknown_action, "sample.unknown"}} =
             Operation.cast(definition, %{"action" => "unknown"})
  end

  test "discovery and authorization annotations derive from the same operations" do
    definition = tool()
    assert definition.name == "sample"
    assert definition.title == "Samples"
    assert definition.input_schema["properties"]["action"]["enum"] == ["create", "list"]
    [create, list] = definition.input_schema["oneOf"]
    assert create["properties"]["action"]["const"] == "create"
    assert create["required"] == ["action", "name"]
    assert list["required"] == ["action"]
    assert definition.annotations.actions["create"].permission == :execute
    assert definition.annotations.actions["list"].recovery == :replay_safe
    assert definition.annotations.readOnlyHint == false
    assert [filtered] = Operation.restrict(definition, ["list"]).input_schema["oneOf"]
    assert filtered["properties"]["action"]["const"] == "list"
  end

  test "duplicates, an action argument and undeclared policy fields refuse at declaration time" do
    op = Operation.new("sample", "list", "List", [], kind: :read, planes: [:external])
    assert_raise ArgumentError, fn -> Operation.tool([op, op]) end

    assert_raise ArgumentError, fn ->
      Operation.new("sample", "bad", "Bad", [Arg.new("action", :string)],
        kind: :read,
        planes: [:external]
      )
    end

    assert_raise ArgumentError, fn ->
      Operation.new("sample", "bad", "Bad", [], kind: :read, planes: [:unknown])
    end

    assert_raise ArgumentError, fn ->
      Operation.new("sample", "bad", "Bad", [],
        kind: :write,
        planes: [:external],
        recovery: :replay_safe
      )
    end
  end

  test "host interception survives materialization and cannot admit catalog in-chain calls" do
    op =
      Operation.new("execution", "run", "Run", [],
        kind: :execute,
        planes: [:external],
        host: :intercepted
      )

    assert Operation.tool([op]).annotations.actions["run"].host == :intercepted
    assert_raise ArgumentError, fn -> Operation.tool([%{op | planes: [:in_chain]}]) end
    assert_raise ArgumentError, fn -> Operation.schema([%{op | host: :unknown}]) end
  end

  test "materialization validates modified declarations before publishing their views" do
    op = Operation.new("sample", "list", "List", [], kind: :read, planes: [:external])
    assert_raise ArgumentError, fn -> Operation.tool([%{op | kind: :unknown}]) end

    assert_raise ArgumentError, fn ->
      Operation.tool([%{op | scope: :platform, planes: [:in_chain]}])
    end

    assert_raise ArgumentError, fn -> Operation.tool([%{op | description: ""}]) end
  end

  test "wire restriction preserves metadata and filters enum and branches together" do
    original = Map.put(tool().input_schema, "description", "Unchanged")
    restricted = Operation.restrict_schema(original, ["list", "unknown"])
    assert restricted["description"] == "Unchanged"
    assert restricted["properties"]["action"]["enum"] == ["list"]
    assert [list] = restricted["oneOf"]
    assert list == List.last(original["oneOf"])
    assert Operation.restrict_schema(original, [])["oneOf"] == []
    external = Map.delete(original, "oneOf")

    assert Operation.restrict_schema(external, ["list"]) ==
             put_in(external, ["properties", "action", "enum"], ["list"])

    assert Operation.restrict_schema(%{"type" => "object"}, ["list"]) == %{"type" => "object"}
    assert Operation.valid_planes() == [:external, :in_chain]
  end
end
