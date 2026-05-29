# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentIdTest do
  use ExUnit.Case, async: true

  alias Compendium.ComponentId

  describe "compute/6" do
    test "is deterministic for the same coordinate" do
      a = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", "default")
      b = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", "default")
      assert a == b
      assert String.starts_with?(a, "comp_")
    end

    test "nil, empty, and the sentinel org_id all collapse to the same id" do
      ids =
        for org <- [nil, "", "local"] do
          ComponentId.compute("foo", "1.0.0", "local", "catalyst", org, "default")
        end

      assert Enum.uniq(ids) |> length() == 1
    end

    test "nil, empty, and the sentinel project_id all collapse to the same id" do
      ids =
        for proj <- [nil, "", "default"] do
          ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", proj)
        end

      assert Enum.uniq(ids) |> length() == 1
    end

    test "a concrete org_id yields a distinct id" do
      local = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", "default")
      acme = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "acme", "default")
      refute local == acme
    end

    test "a concrete project_id yields a distinct id" do
      default = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", "default")
      other = ComponentId.compute("foo", "1.0.0", "local", "catalyst", "local", "proj_x")
      refute default == other
    end
  end
end
