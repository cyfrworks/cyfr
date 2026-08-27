# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.PathSafetyTest do
  use ExUnit.Case, async: true

  alias Cyfr.PathSafety

  describe "validate_segments!/1 (Arca contract)" do
    test "accepts ordinary segments" do
      assert :ok = PathSafety.validate_segments!(["guest", "notes", "started.json"])
    end

    test "rejects literal .. segments" do
      assert_raise ArgumentError, ~r/segment ".." is not allowed/, fn ->
        PathSafety.validate_segments!(["guest", "..", "etc", "passwd"])
      end
    end

    test "rejects null bytes" do
      assert_raise ArgumentError, ~r/null bytes/, fn ->
        PathSafety.validate_segments!(["file" <> <<0>> <> ".txt"])
      end
    end

    test "rejects multi-layer encoded traversal" do
      assert_raise ArgumentError, ~r/encoded dot segments/, fn ->
        PathSafety.validate_segments!(["%252e%252e/secrets"])
      end
    end

    test "rejects dot, encoded dot, and empty segments" do
      assert_raise ArgumentError, ~r/segment "\."/, fn ->
        PathSafety.validate_segments!([".", "x"])
      end

      assert_raise ArgumentError, ~r/encoded dot segments/, fn ->
        PathSafety.validate_segments!(["%2e"])
      end

      assert_raise ArgumentError, ~r/empty segments/, fn ->
        PathSafety.validate_segments!(["a", ""])
      end
    end

    test "rejects backslashes" do
      assert_raise ArgumentError, ~r/backslashes/, fn ->
        PathSafety.validate_segments!(["..\\..\\windows"])
      end
    end

    test "rejects absolute segments" do
      assert_raise ArgumentError, ~r/absolute segments/, fn ->
        PathSafety.validate_segments!(["/etc", "passwd"])
      end
    end
  end

  describe "validate_relative_path/1 (Opus contract)" do
    test "accepts ordinary relative paths" do
      assert :ok = PathSafety.validate_relative_path("data/cache/results.json")
      assert :ok = PathSafety.validate_relative_path("")
    end

    test "rejects absolute paths" do
      assert {:error, message} = PathSafety.validate_relative_path("/etc/passwd")
      assert message =~ "Absolute paths"
    end

    test "rejects .. traversal" do
      assert {:error, message} =
               PathSafety.validate_relative_path("components/agent/../../evil/x.wasm")

      assert message =~ ".."
    end

    test "rejects null bytes (gained from the Arca side of the merge)" do
      assert {:error, message} = PathSafety.validate_relative_path("data/x" <> <<0>> <> "y")
      assert message =~ "null bytes"
    end

    test "rejects encoded traversal (gained from the Arca side of the merge)" do
      assert {:error, message} = PathSafety.validate_relative_path("data/%2e%2e/secrets")
      assert message =~ "encoded"
    end

    test "rejects backslashes" do
      assert {:error, message} = PathSafety.validate_relative_path("data\\..\\secrets")
      assert message =~ "backslashes"
    end
  end

  describe "length and depth ceilings (both contracts)" do
    test "a 240-byte segment passes; 241 is refused — measured in bytes, not graphemes" do
      assert :ok = PathSafety.validate_segments!(["guest", String.duplicate("a", 240)])

      assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
        PathSafety.validate_segments!(["guest", String.duplicate("a", 241)])
      end

      # 81 three-byte graphemes are 243 bytes: past the ceiling even though
      # the grapheme count is far under it.
      assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
        PathSafety.validate_segments!(["guest", String.duplicate("四", 81)])
      end

      assert {:error, message} =
               PathSafety.validate_relative_path("data/" <> String.duplicate("a", 241))

      assert message =~ "segment longer than 240 bytes"
    end

    test "depth past 32 segments is refused" do
      deep_ok = ["guest" | for(n <- 1..31, do: "d#{n}")]
      assert :ok = PathSafety.validate_segments!(deep_ok)

      deep_bad = ["guest" | for(n <- 1..32, do: "d#{n}")]

      assert_raise ArgumentError, ~r/more than 32 segments/, fn ->
        PathSafety.validate_segments!(deep_bad)
      end

      assert {:error, message} = PathSafety.validate_relative_path(Enum.join(deep_bad, "/"))
      assert message =~ "more than 32 segments"
    end

    test "a joined path past 1024 bytes is refused" do
      # Eight 200-byte segments: each under the segment cap, 1607 joined.
      long = ["guest" | for(_ <- 1..8, do: String.duplicate("a", 200))]

      assert_raise ArgumentError, ~r/longer than 1024 bytes/, fn ->
        PathSafety.validate_segments!(long)
      end
    end
  end

  describe "validate_segments/1 (tuple contract)" do
    test "answers instead of raising — the exists? contract" do
      assert :ok = PathSafety.validate_segments(["guest", "notes.txt"])
      assert {:error, message} = PathSafety.validate_segments(["guest", ".."])
      assert message =~ "not allowed"
    end
  end
end
