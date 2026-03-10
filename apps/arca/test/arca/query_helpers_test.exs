defmodule Arca.QueryHelpersTest do
  use ExUnit.Case, async: true

  alias Arca.QueryHelpers

  describe "normalize_org_id/1" do
    test "converts nil to empty string sentinel" do
      assert QueryHelpers.normalize_org_id(nil) == ""
    end

    test "passes through non-nil org_id" do
      assert QueryHelpers.normalize_org_id("org-123") == "org-123"
    end

    test "passes through empty string" do
      assert QueryHelpers.normalize_org_id("") == ""
    end
  end

  describe "maybe_put/3" do
    test "adds key-value when value is non-nil" do
      assert QueryHelpers.maybe_put([], :limit, 10) == [limit: 10]
    end

    test "returns list unchanged when value is nil" do
      assert QueryHelpers.maybe_put([limit: 10], :status, nil) == [limit: 10]
    end

    test "overwrites existing key" do
      assert QueryHelpers.maybe_put([limit: 10], :limit, 20) == [limit: 20]
    end

    test "works with empty list and nil" do
      assert QueryHelpers.maybe_put([], :key, nil) == []
    end
  end
end
