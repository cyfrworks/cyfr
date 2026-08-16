# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentIdTest do
  use ExUnit.Case, async: true

  alias Compendium.ComponentId

  describe "compute/5" do
    test "is deterministic for the same coordinate" do
      a = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "ath_a")
      b = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "ath_a")
      assert a == b
      assert String.starts_with?(a, "comp_")
    end

    test "a different athanor yields a distinct id" do
      a = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "ath_a")
      b = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "ath_b")
      refute a == b
    end

    test "nil, empty, and the local publisher all collapse to the same id" do
      ids =
        for pub <- [nil, "", "local"] do
          ComponentId.compute("foo", "1.0.0", pub, "catalyst", "ath_a")
        end

      assert Enum.uniq(ids) |> length() == 1
    end

    test "an unresolved athanor is refused" do
      for bad <- [nil, ""] do
        assert_raise FunctionClauseError, fn ->
          ComponentId.compute("foo", "1.0.0", "local", "catalyst", bad)
        end
      end
    end
  end
end
