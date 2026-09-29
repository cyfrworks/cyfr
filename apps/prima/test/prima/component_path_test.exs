# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentPathTest do
  use ExUnit.Case, async: true

  alias Prima.ComponentPath

  doctest Prima.ComponentPath

  describe "publisher/1" do
    test "reads back the publisher version_dir/4 lays out, at and below the version" do
      for publisher <- ["local", "acme", "stripe.com", nil] do
        dir = ComponentPath.version_dir("catalyst", publisher, "tool", "1.0.0")
        expected = ComponentPath.normalize_publisher(publisher)

        assert ComponentPath.publisher(dir) == {:ok, expected}
        assert ComponentPath.publisher(dir ++ ["src", "lib.rs"]) == {:ok, expected}
      end
    end

    test "reads a publisher directory and anything under it, whatever the domain grammar says" do
      # Positions only: a unit's validity is the component domain's
      # grammar, and a caller holds a unit that grammar located.
      assert ComponentPath.publisher(["components", "catalysts", "acme"]) == {:ok, "acme"}
      assert ComponentPath.publisher(["components", "catalysts", "acme", "tool"]) == {:ok, "acme"}
    end

    test "a path outside the tree, or above a publisher directory, has none" do
      for segments <- [
            [],
            ["components"],
            ["components", "catalysts"],
            ["data", "catalysts", "acme", "tool", "1.0.0"],
            ["aqua", "roles", "writer.md"],
            ["aqua", "skills", "tidy", "SKILL.md"]
          ] do
        assert ComponentPath.publisher(segments) == :error, inspect(segments)
      end
    end
  end
end
