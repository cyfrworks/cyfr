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
end
