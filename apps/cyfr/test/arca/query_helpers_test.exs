defmodule Arca.QueryHelpersTest do
  use ExUnit.Case, async: true

  alias Arca.QueryHelpers
  alias Sanctum.Context

  import Ecto.Query

  defp base_query, do: from(e in Arca.Execution)

  describe "where_tenant/3" do
    test "applies both org_id and project_id filters" do
      ctx = Context.build(user_id: "u1", org_id: "org_1", project_id: "proj_1")
      query = QueryHelpers.where_tenant(base_query(), ctx)

      %{wheres: wheres} = query
      assert length(wheres) == 2
    end

    test "nil org_id uses empty string sentinel" do
      ctx = Context.build(user_id: "u1", project_id: "proj_1")
      query = QueryHelpers.where_tenant(base_query(), ctx)

      %{wheres: wheres} = query
      assert length(wheres) == 2
    end

    test "nil project_id uses default sentinel" do
      ctx = Context.build(user_id: "u1", org_id: "org_1")
      query = QueryHelpers.where_tenant(base_query(), ctx)

      %{wheres: wheres} = query
      assert length(wheres) == 2
    end

    test "skip_project: true applies only org_id" do
      ctx = Context.build(user_id: "u1", org_id: "org_1", project_id: "proj_1")
      query = QueryHelpers.where_tenant(base_query(), ctx, skip_project: true)

      %{wheres: wheres} = query
      assert length(wheres) == 1
    end
  end

  describe "where_project_id/2" do
    test "nil project_id uses default sentinel" do
      query = QueryHelpers.where_project_id(base_query(), nil)
      %{wheres: wheres} = query
      assert length(wheres) == 1
    end

    test "non-nil project_id uses provided value" do
      query = QueryHelpers.where_project_id(base_query(), "proj_1")
      %{wheres: wheres} = query
      assert length(wheres) == 1
    end
  end

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
