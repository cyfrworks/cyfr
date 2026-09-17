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
    schema = definition.input_schema
    assert schema["properties"]["action"]["enum"] == ["create", "list"]

    # One flat object: a model API refuses oneOf/anyOf/allOf at the top
    # level of a tool schema. `name` is required by `create` alone, so the
    # shared schema requires only the discriminator and says who uses it.
    refute Map.has_key?(schema, "oneOf")
    assert schema["additionalProperties"] == false
    assert Map.has_key?(schema["properties"], "name")
    assert Map.has_key?(schema["properties"], "limit")
    assert schema["required"] == ["action"]
    assert schema["properties"]["name"]["description"] =~ "Actions: create."
    assert schema["properties"]["limit"]["minimum"] == 0
    assert definition.annotations.actions["create"].permission == :execute
    assert definition.annotations.actions["list"].recovery == :replay_safe
    assert definition.annotations.readOnlyHint == false

    restricted = Operation.restrict(definition, ["list"]).input_schema
    assert restricted["properties"]["action"]["enum"] == ["list"]
    refute Map.has_key?(restricted["properties"], "name")
    assert Map.has_key?(restricted["properties"], "limit")
  end

  test "a shared argument merges to its loosest declaration and refuses a shape conflict" do
    approve =
      Operation.new(
        "card",
        "approve",
        "Approve",
        [
          Arg.new("scope", :string,
            enum: ["once", "thread"],
            required: true,
            min: 1,
            max: 8,
            pattern: "^[a-z]+$",
            description: "How far the decision reaches"
          )
        ],
        kind: :write,
        planes: [:external]
      )

    decline =
      Operation.new(
        "card",
        "decline",
        "Decline",
        [Arg.new("scope", :string, enum: ["never"], nullable: true, min: 2, max: 9)],
        kind: :write,
        planes: [:external]
      )

    schema = Operation.schema([approve, decline])
    scope = schema["properties"]["scope"]
    assert scope["type"] == ["string", "null"]
    assert scope["enum"] == ["once", "thread", "never", nil]
    assert {scope["minLength"], scope["maxLength"]} == {1, 9}
    refute Map.has_key?(scope, "pattern")
    assert scope["description"] == "How far the decision reaches"
    assert schema["required"] == ["action"]

    conflict =
      Operation.new("card", "count", "Count", [Arg.new("scope", :integer)],
        kind: :read,
        planes: [:external]
      )

    assert_raise ArgumentError, ~r/different types/, fn ->
      Operation.schema([approve, conflict])
    end
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

  test "wire restriction narrows the action enum and keeps everything else" do
    original = Map.put(tool().input_schema, "description", "Unchanged")
    restricted = Operation.restrict_schema(original, ["list", "unknown"])
    assert restricted["description"] == "Unchanged"
    assert restricted["properties"]["action"]["enum"] == ["list"]
    assert restricted["properties"]["name"] == original["properties"]["name"]
    assert Operation.restrict_schema(original, [])["properties"]["action"]["enum"] == []
    assert Operation.restrict_schema(%{"type" => "object"}, ["list"]) == %{"type" => "object"}
    assert Operation.valid_planes() == [:external, :in_chain]
  end
end
