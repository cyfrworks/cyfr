# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.OriginTest do
  @moduledoc """
  The closed origin enum and its wire spellings: four values, each spelled
  as its name, and nothing else read as one.
  """

  use ExUnit.Case, async: true

  alias Prima.Origin

  test "the enum is closed at four, spelled as their names" do
    assert Origin.values() == [:interactive, :programmatic, :schedule, :webhook]
    assert Origin.spellings() == ["interactive", "programmatic", "schedule", "webhook"]

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
end
