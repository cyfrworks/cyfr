# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.DiscoverySchemaTest do
  @moduledoc """
  Every registered tool's discovery schema is one a model API accepts.
  Anthropic refuses `oneOf`, `anyOf` and `allOf` at the top level of a
  tool's input schema, and the Claude catalyst forwards a tool schema
  verbatim, so the catalog renders one flat object per tool.
  """

  use ExUnit.Case, async: false

  alias Grimoire.Catalog

  @combinators ~w(oneOf anyOf allOf not if then else)

  test "every registered tool renders one flat object schema" do
    tools = Catalog.list_tools()
    assert [_ | _] = tools

    for %{"name" => name, "inputSchema" => schema} = tool <- tools,
        not String.contains?(name, ":") do
      assert schema["type"] == "object", "#{name}: not an object schema"
      assert schema["additionalProperties"] == false, "#{name}: open object"

      for combinator <- @combinators do
        refute Map.has_key?(schema, combinator), "#{name}: top-level #{combinator}"
      end

      properties = schema["properties"]
      assert is_map(properties), "#{name}: no properties"
      assert Enum.all?(properties, fn {_key, value} -> is_map(value) end), "#{name}: property"

      assert Enum.all?(schema["required"], &Map.has_key?(properties, &1)),
             "#{name}: required names an undeclared property"

      assert %{"type" => "string", "enum" => [_ | _] = actions} = properties["action"]
      assert Enum.sort(actions) == tool["annotations"].actions |> Map.keys() |> Enum.sort()
      assert is_binary(Jason.encode!(schema))
    end
  end
end
