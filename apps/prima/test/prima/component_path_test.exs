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

  describe "path_granted?/2" do
    test "a prefix grant admits what it prefixes and its bare directory, and nothing beside it" do
      grants = ["data/notes/"]

      for path <- ["data/notes/today.md", "data/notes/2026/09/a.md", "data/notes/", "data/notes"] do
        assert ComponentPath.path_granted?(path, grants), path
      end

      for path <- ["data/notesheet.md", "data/note", "data", "data/", "data/other/notes/a.md"] do
        refute ComponentPath.path_granted?(path, grants), path
      end
    end

    test "any other grant admits exactly the path it spells" do
      grants = ["data/report.md"]

      assert ComponentPath.path_granted?("data/report.md", grants)

      for path <- ["data/report.md/", "data/report.md/x", "data/report", "data/report.mdx"] do
        refute ComponentPath.path_granted?(path, grants), path
      end
    end

    test "the wildcard admits every path, and no grant admits nothing" do
      for path <- ["", "data/a", "components/catalysts/local/x/1.0.0/src/lib.rs"] do
        assert ComponentPath.path_granted?(path, ["*"]), path
        refute ComponentPath.path_granted?(path, []), path
      end

      # A pattern is never read as a glob: only the bare wildcard is one.
      refute ComponentPath.path_granted?("data/a", ["data/*"])
      refute ComponentPath.path_granted?("data/a", ["*/"])
    end

    test "any grant of several admits, and each side compares as spelled" do
      assert ComponentPath.path_granted?("data/b/x", ["data/a/", "data/b/"])

      # Nothing is trimmed or resolved here: the caller refuses an unsafe
      # path first, and a spelling with an empty segment is its own path.
      refute ComponentPath.path_granted?("data//notes/a.md", ["data/notes/"])
      refute ComponentPath.path_granted?("/data/notes/a.md", ["data/notes/"])
      assert ComponentPath.path_granted?("data/notes/../../etc", ["data/notes/"])
    end

    test "a value that is no path or no grant list admits nothing" do
      refute ComponentPath.path_granted?(nil, ["*"])
      refute ComponentPath.path_granted?("data/a", nil)
      refute ComponentPath.path_granted?("data/a", [nil, 7])
    end
  end

  describe "door_path/1" do
    test "a folder keeps its trailing slash" do
      assert ComponentPath.door_path("data/notes/") == "data/notes/"
      assert ComponentPath.door_path("data/") == "data/"
    end

    test "a file is spelled as it is" do
      assert ComponentPath.door_path("data/notes/today.md") == "data/notes/today.md"
    end

    test "an empty path names nothing" do
      for empty <- ["", "/", "//", "///"] do
        assert ComponentPath.door_path(empty) == nil, inspect(empty)
      end
    end

    test "an absolute path is not the door's" do
      assert ComponentPath.door_path("/data/notes/") == nil
      assert ComponentPath.door_path("/etc/passwd") == nil
    end

    test "a path the door's check refuses is none" do
      for unsafe <- ["data/../secrets", "../data", "data/./notes", "data/\0/x"] do
        assert ComponentPath.door_path(unsafe) == nil, inspect(unsafe)
      end
    end

    test "doubled slashes are trimmed, so a picked path matches the call it covers" do
      assert ComponentPath.door_path("data//notes/today.md") == "data/notes/today.md"
      assert ComponentPath.door_path("data//notes//") == "data/notes/"
      assert ComponentPath.door_path("data///reports") == "data/reports"
    end

    test "anything but a string is none" do
      assert ComponentPath.door_path(nil) == nil
      assert ComponentPath.door_path(["data"]) == nil
    end
  end
end
