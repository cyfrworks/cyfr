defmodule Arca.StorageTest do
  use ExUnit.Case, async: true

  alias Arca.Storage

  describe "validate_path!/1" do
    test "accepts valid path segments" do
      assert :ok = Storage.validate_path!(["executions", "exec_123", "started.json"])
    end

    test "accepts single segment" do
      assert :ok = Storage.validate_path!(["components"])
    end

    test "accepts empty list" do
      assert :ok = Storage.validate_path!([])
    end

    test "rejects path traversal with .." do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["executions", "..", "..", "etc", "passwd"])
      end
    end

    test "rejects .. even as first segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["..", "secret"])
      end
    end

    test "rejects .. as only segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!([".."])
      end
    end

    test "allows single dot segment" do
      assert :ok = Storage.validate_path!([".", "file.txt"])
    end

    test "allows segments containing .. in names" do
      assert :ok = Storage.validate_path!(["file..bak", "test"])
    end
  end

  describe "global_prefixes/0" do
    test "returns expected prefixes" do
      prefixes = Storage.global_prefixes()
      assert "cache" in prefixes
      refute "mcp_logs" in prefixes
    end

    test "returns a list" do
      assert is_list(Storage.global_prefixes())
    end
  end
end
