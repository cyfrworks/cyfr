# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ExecutionGrantTest do
  @moduledoc """
  A grant names one estate and one positive generation of its standing,
  and nothing else: no permission, no credential. A malformed estate id or
  generation is refused rather than coerced.
  """
  use ExUnit.Case, async: true

  alias Cyfr.ExecutionGrant

  test "a grant is an estate and a positive generation" do
    assert {:ok, %ExecutionGrant{athanor_id: "ath_a", generation: 1} = grant} =
             ExecutionGrant.new("ath_a", 1)

    assert ExecutionGrant.valid?(grant)
    assert {:ok, %ExecutionGrant{generation: 42}} = ExecutionGrant.new("ath_a", 42)
  end

  test "a malformed estate or generation is refused" do
    for {athanor_id, generation} <- [
          {"", 1},
          {nil, 1},
          {:ath_a, 1},
          {"ath_a", 0},
          {"ath_a", -1},
          {"ath_a", 1.0},
          {"ath_a", "1"},
          {"ath_a", nil}
        ] do
      assert {:error, :invalid_grant} = ExecutionGrant.new(athanor_id, generation),
             "#{inspect({athanor_id, generation})} is not a grant"
    end
  end

  test "only a well-formed struct is a grant" do
    refute ExecutionGrant.valid?(%ExecutionGrant{athanor_id: "ath_a", generation: 0})
    refute ExecutionGrant.valid?(%ExecutionGrant{athanor_id: nil, generation: 1})
    refute ExecutionGrant.valid?(%{athanor_id: "ath_a", generation: 1})
    refute ExecutionGrant.valid?(nil)
  end

  test "a grant carries no permission or credential field" do
    assert ExecutionGrant.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [:athanor_id, :generation]
  end
end
