# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusPoolTest do
  @moduledoc """
  The pool's numbers and their vector file (`tests/fixtures/locus_pool.json`)
  are one definition: the file holds the module's values under exactly its
  keys, which the keeper's own test reads.
  """
  use ExUnit.Case, async: true

  @vectors Path.expand("../../../../tests/fixtures/locus_pool.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "the vector file holds the module's numbers and nothing else" do
    assert Map.keys(@vectors) |> Enum.sort() == ~w(comment floor_bytes)
    assert @vectors["floor_bytes"] == Prima.LocusPool.floor_bytes()
    assert Prima.LocusPool.floor_bytes() == 164 * 1024 * 1024
  end
end
