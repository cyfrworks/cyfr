# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.CliGenerationTest do
  use ExUnit.Case, async: true

  alias Prima.{Arg, Operation}
  alias Mix.Tasks.Ops.Gen.Cli

  test "argument declarations determine Go field types, presence and nested records" do
    operation =
      Operation.new(
        "example",
        "write",
        "Write example",
        [
          Arg.new("count", :integer, required: true),
          Arg.new("enabled", :boolean),
          Arg.new("label", :string, nullable: true),
          Arg.new("reason", :string, required: true, nullable: true),
          Arg.new(
            "items",
            {:array, Arg.new(nil, {:record, [Arg.new("name", :string, required: true)]})}
          ),
          Arg.new("input", {:map, Arg.new(nil, :json)})
        ],
        kind: :write,
        planes: [:external]
      )

    rendered = Cli.render([operation])
    assert rendered =~ "type ExampleWriteArgs struct"
    assert rendered =~ ~s(Count int `json:"count"`)
    assert rendered =~ ~s(Enabled Field[bool] `json:"enabled,omitzero"`)
    assert rendered =~ "Label Field[*string]"
    assert rendered =~ "Reason *string"
    assert rendered =~ "Items Field[[]ExampleWriteArgsItemsItem]"
    assert rendered =~ "Input Field[map[string]any]"
    assert rendered =~ "Action: ExampleWrite"
    assert rendered =~ "decodeRecord(data, &value)"

    changed = %{operation | args: [Arg.new("count", :number, required: true)]}
    refute Cli.current?({:ok, rendered}, Cli.render([changed]))
  end

  test "drift comparison preserves literals, tokens and comment boundaries" do
    assert Cli.current?(
             {:ok, "type Example struct {\n Count int\n}"},
             "type Example struct { Count int }"
           )

    refute Cli.current?(
             {:ok, "type Example struct { Countint }"},
             "type Example struct { Count int }"
           )

    refute Cli.current?({:ok, ~s(const Name = "two  spaces")}, ~s(const Name = "two spaces"))
    refute Cli.current?({:ok, "// description Count int"}, "// description\nCount int")
  end
end
