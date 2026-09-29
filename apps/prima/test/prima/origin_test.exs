# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.OriginTest do
  @moduledoc """
  The closed origin enum and its wire spellings: four values, each spelled
  as its name, and nothing else read as one. The spellings are also
  `tests/fixtures/consent_preview.json`'s, where a grant's admitted origins
  travel.
  """

  use ExUnit.Case, async: true

  alias Prima.Origin

  @vectors Path.expand("../../../../tests/fixtures/consent_preview.json", __DIR__)

  test "the enum is closed at four, spelled as their names" do
    assert Origin.values() == [:interactive, :programmatic, :schedule, :webhook]
    assert Origin.spellings() == ["interactive", "programmatic", "schedule", "webhook"]

    fixture = @vectors |> File.read!() |> Jason.decode!()
    assert fixture["origins"]["spellings"] == Origin.spellings()

    for origin <- Origin.values() do
      assert Origin.origin?(origin)
      assert Origin.from_wire(Origin.to_wire(origin)) == {:ok, origin}
    end
  end

  test "a value outside the enum is refused" do
    for spelling <- ["cli", "Interactive", "INTERACTIVE", "", "api", nil, :interactive, 1] do
      assert Origin.from_wire(spelling) == {:error, {:unknown_origin, spelling}}
    end

    refute Origin.origin?(:cli)
  end

  test "a grant's origins are a non-empty set, answered in the enum's order" do
    assert Origin.parse_list(["webhook", "interactive"]) == {:ok, [:interactive, :webhook]}
    assert Origin.parse_list([]) == {:error, :empty_origins}
    assert Origin.parse_list(nil) == {:error, :empty_origins}
    assert Origin.parse_list(["schedule", "schedule"]) == {:error, :duplicate_origin}
    assert Origin.parse_list(["interactive", "cli"]) == {:error, {:unknown_origin, "cli"}}
    assert Origin.to_wire_list([:webhook, :interactive]) == ["interactive", "webhook"]
  end
end
