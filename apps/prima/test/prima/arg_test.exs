# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ArgTest do
  use ExUnit.Case, async: true

  alias Prima.Arg

  test "presence preserves omitted, null, false, zero and empty values" do
    args = [
      Arg.new("required", :string, required: true),
      Arg.new("nullable", :string, nullable: true),
      Arg.new("enabled", :boolean),
      Arg.new("count", :integer, min: 0)
    ]

    input = %{"required" => "", "nullable" => nil, "enabled" => false, "count" => 0}
    assert {:ok, ^input} = Arg.cast(args, input)
    assert {:ok, %{"required" => "x"}} = Arg.cast(args, %{"required" => "x"})
    assert {:error, _} = Arg.cast(args, %{})
    assert {:error, _} = Arg.cast(args, %{"required" => nil})
    assert {:error, _} = Arg.cast(args, %{"required" => "x", "enabled" => "false"})
    assert {:error, _} = Arg.cast(args, %{"required" => "x", "count" => "0"})
  end

  test "records are closed at every depth and arrays validate each item" do
    args = [
      Arg.new(
        "edits",
        {:array,
         Arg.new(
           nil,
           {:record,
            [
              Arg.new("path", :string, required: true),
              Arg.new("lines", {:array, Arg.new(nil, :integer, min: 1)}, required: true)
            ]}
         )},
        required: true,
        min: 1,
        max: 2
      )
    ]

    valid = %{"edits" => [%{"path" => "src/main.rs", "lines" => [1, 2]}]}
    assert {:ok, ^valid} = Arg.cast(args, valid)
    assert {:error, _} = Arg.cast(args, Map.put(valid, "unknown", true))
    assert {:error, _} = Arg.cast(args, %{"edits" => [%{"path" => "x", "lines" => [0]}]})

    assert {:error, _} =
             Arg.cast(args, %{"edits" => [%{"path" => "x", "lines" => [1], "extra" => true}]})

    assert {:error, _} = Arg.cast(args, %{"edits" => []})
    assert {:error, _} = Arg.cast(args, %{"edits" => List.duplicate(hd(valid["edits"]), 3)})
  end

  test "intentionally open JSON and typed maps retain arbitrary keys" do
    args = [
      Arg.new("input", {:map, Arg.new(nil, :json)}),
      Arg.new("headers", {:map, Arg.new(nil, :string)}, max: 2)
    ]

    input = %{
      "input" => %{"arbitrary" => [nil, false, 1, %{"nested" => "yes"}]},
      "headers" => %{"X-Name" => "test"}
    }

    assert {:ok, ^input} = Arg.cast(args, input)
    assert {:error, _} = Arg.cast(args, %{"headers" => %{"X-Name" => 1}})
    assert {:error, _} = Arg.cast(args, %{"input" => %{bad: :not_json}})
    assert {:error, _} = Arg.cast(args, %{"headers" => %{"a" => "a", "b" => "b", "c" => "c"}})
  end

  test "string, numeric and enum constraints all apply" do
    args = [
      Arg.new("name", :string, min: 2, max: 4, pattern: "^[a-z]+$"),
      Arg.new("limit", :number, min: 0, max: 2),
      Arg.new("choice", :string, enum: ["a", "b"], nullable: true)
    ]

    assert {:ok, _} = Arg.cast(args, %{"name" => "ab", "limit" => 0, "choice" => nil})

    for input <- [
          %{"name" => "a"},
          %{"name" => "abcde"},
          %{"name" => "A1"},
          %{"limit" => -1},
          %{"limit" => 3},
          %{"choice" => "c"}
        ] do
      assert {:error, _} = Arg.cast(args, input)
    end
  end

  test "generated schema carries the enforced constraints and action-independent presence" do
    args = [
      Arg.new(
        "items",
        {:array,
         Arg.new(
           nil,
           {:record,
            [
              Arg.new("count", :integer, min: 0, max: 5, required: true),
              Arg.new("name", :string, min: 1, max: 20, pattern: "^[a-z]+$", nullable: true)
            ]}
         )},
        required: true,
        min: 1,
        max: 3
      )
    ]

    schema = Arg.schema(args)
    assert schema["additionalProperties"] == false
    assert schema["required"] == ["items"]
    items = schema["properties"]["items"]
    assert items["minItems"] == 1 and items["maxItems"] == 3
    assert items["items"]["additionalProperties"] == false
    assert items["items"]["required"] == ["count"]
    assert items["items"]["properties"]["count"]["minimum"] == 0
    assert items["items"]["properties"]["count"]["maximum"] == 5
    assert items["items"]["properties"]["name"]["type"] == ["string", "null"]
    assert items["items"]["properties"]["name"]["pattern"] == "^[a-z]+$"
  end

  test "bad declarations fail before they can be used as contracts" do
    assert_raise ArgumentError, fn -> Arg.new("name", :string, pattern: "[") end
    assert_raise ArgumentError, fn -> Arg.new("limit", :integer, min: 5, max: 1) end
    assert_raise ArgumentError, fn -> Arg.new("name", :unknown) end

    assert_raise ArgumentError, fn ->
      Arg.schema([Arg.new("same", :string), Arg.new("same", :integer)])
    end
  end

  test "invalid arguments never echo their values in errors" do
    secret = "private-value-never-repeat"
    assert {:error, message} = Arg.cast([Arg.new("token", :integer)], %{"token" => secret})
    refute message =~ secret
  end

  test "a changed declaration drives validation and discovery together" do
    original = Arg.new("name", :string, pattern: "^[a-z]+$")
    changed = %{original | pattern: "^[0-9]+$"}
    assert {:error, _} = Arg.cast([original], %{"name" => "123"})
    assert {:ok, _} = Arg.cast([changed], %{"name" => "123"})
    assert {:error, _} = Arg.cast([changed], %{"name" => "abc"})
    assert Arg.schema([changed])["properties"]["name"]["pattern"] == "^[0-9]+$"
  end

  test "defaults are discovery hints and never turn an omitted update into a write" do
    arg = Arg.new("count", :integer, default: 20)
    assert {:ok, %{}} = Arg.cast([arg], %{})
    assert Arg.schema([arg])["properties"]["count"]["default"] == 20
  end

  test "string bounds count Unicode code points rather than bytes or graphemes" do
    args = [Arg.new("text", :string, max: 1)]
    assert {:ok, _} = Arg.cast(args, %{"text" => "🙂"})
    assert {:error, _} = Arg.cast(args, %{"text" => "e\u0301"})
  end

  test "enum members and discovery defaults satisfy their declared value contract" do
    assert_raise ArgumentError, fn -> Arg.new("count", :integer, enum: ["1"]) end
    assert_raise ArgumentError, fn -> Arg.new("count", :integer, enum: [0], min: 1) end
    assert_raise ArgumentError, fn -> Arg.new("count", :integer, default: nil) end
    assert_raise ArgumentError, fn -> Arg.new("count", :integer, default: 2, enum: [1]) end

    assert_raise ArgumentError, fn ->
      Arg.new("name", :string, default: "A", pattern: "^[a-z]+$")
    end

    assert Arg.new("count", :integer, nullable: true, default: nil).default == nil
  end

  test "numeric enums compare JSON numeric values independently of representation" do
    args = [Arg.new("value", :number, enum: [1])]
    assert {:ok, %{"value" => 1.0}} = Arg.cast(args, %{"value" => 1.0})
    assert {:error, _} = Arg.cast(args, %{"value" => 2.0})
  end

  test "integral JSON numbers normalize recursively only at integer declarations" do
    args = [
      Arg.new("count", :integer, min: 0, max: 2, enum: [0, 1.0, 2]),
      Arg.new("record", {:record, [Arg.new("value", :integer, nullable: true)]}),
      Arg.new("items", {:array, Arg.new(nil, :integer)}),
      Arg.new("map", {:map, Arg.new(nil, :integer)}),
      Arg.new("number", :number),
      Arg.new("json", :json)
    ]

    input = %{
      "count" => 1.0,
      "record" => %{"value" => nil},
      "items" => [0.0, -2.0],
      "map" => %{"one" => 1.0},
      "number" => 1.0,
      "json" => %{"value" => 1.0}
    }

    assert {:ok, result} = Arg.cast(args, input)
    assert result === %{input | "count" => 1, "items" => [0, -2], "map" => %{"one" => 1}}

    assert {:ok, %{"record" => %{"value" => 2}}} =
             Arg.cast(args, %{"record" => %{"value" => 2.0}})

    assert {:ok, %{}} = Arg.cast(args, %{})

    for invalid <- [1.5, "1", true, nil, 3.0] do
      assert {:error, _} = Arg.cast(args, %{"count" => invalid})
    end

    assert Arg.schema(args)["properties"]["count"]["type"] == "integer"
    assert_raise ArgumentError, fn -> Arg.new("count", :integer, default: 1.0) end
  end
end
