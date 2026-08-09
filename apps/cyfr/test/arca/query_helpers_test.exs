# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  describe "where_tenant/3 org-less fail-closed backstop" do
    test "authenticated org-scoped context with nil org_id raises" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          org_id: nil,
          project_id: "p1",
          scope: :org,
          authenticated: true
        )

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "authenticated project-scoped context with nil org_id raises" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          org_id: nil,
          project_id: "p1",
          scope: :project,
          authenticated: true
        )

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "a hand-rolled struct with an empty-string org_id raises" do
      # Context.build/1 coerces "" to the sentinel, so only a struct literal
      # can carry "" — the guard must still fail closed on it.
      ctx = %Context{
        user_id: "u1",
        org_id: "",
        project_id: "p1",
        scope: :project,
        authenticated: true
      }

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end

    test "platform-scope context with nil org_id passes (scoped to the sentinel)" do
      ctx =
        Context.build(
          user_id: "admin",
          org_id: nil,
          scope: :platform,
          authenticated: true
        )

      query = QueryHelpers.where_tenant(base_query(), ctx)
      assert length(query.wheres) == 2
    end

    test "the seeded local context passes unchanged" do
      ctx = Sanctum.TestContext.local()
      query = QueryHelpers.where_tenant(base_query(), ctx)
      assert length(query.wheres) == 2
    end

    test "unauthenticated org-less context still scopes to the sentinel (no raise)" do
      ctx = Context.build(user_id: "u1", org_id: nil, project_id: "p1")
      query = QueryHelpers.where_tenant(base_query(), ctx)
      assert length(query.wheres) == 2
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
    test "converts nil to the seeded local sentinel" do
      assert QueryHelpers.normalize_org_id(nil) == "local"
    end

    test "passes through a non-empty org_id" do
      assert QueryHelpers.normalize_org_id("org-123") == "org-123"
    end

    test "converts an empty string to the local sentinel" do
      assert QueryHelpers.normalize_org_id("") == "local"
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
