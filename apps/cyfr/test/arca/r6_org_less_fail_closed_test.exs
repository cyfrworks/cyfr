# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.R6OrgLessFailClosedTest do
  @moduledoc """
  Defense-in-depth: an org-less *tenant* context must never alias another
  org's rows.

  1. Read path — `Arca.QueryHelpers.where_tenant/3` raises for an
     authenticated non-platform context with a nil/"" org, so a store that
     forgets the Sanctum chokepoint still cannot read the seeded local org's
     rows. The bare-key `where_org_id/2` filter canonicalizes nil/"" to the
     local sentinel (org strings carry no authentication state to judge).
  2. Write path / chokepoint — `Sanctum.Permission` calls
     `Context.require_tenant!`, and `Arca.Storage.tenant_segments/1` fails
     closed for a nil/"" org. The seeded `"local"` org substitutes the
     namespace (single-user layout); a genuinely org-less context raises.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Sanctum.Context

  defp base_query, do: from(e in Arca.Execution)
  defp last_where_expr(%{wheres: wheres}), do: List.last(wheres).expr

  describe "where_org_id/2 — org-less canonicalizes to the local org" do
    test "org-less (nil) produces a normal org equality (canonicalized to local)" do
      q = QueryHelpers.where_org_id(base_query(), nil)
      refute last_where_expr(q) == false
    end

    test "org-less (\"\") produces a normal org equality (canonicalized to local)" do
      q = QueryHelpers.where_org_id(base_query(), "")
      refute last_where_expr(q) == false
    end

    test "a real org produces a normal equality" do
      q = QueryHelpers.where_org_id(base_query(), "org_alpha")
      refute last_where_expr(q) == false
    end

    test "where_tenant/3 scopes an org-less UNauthenticated context to org + project" do
      ctx = Context.build(user_id: "u1", org_id: nil, project_id: "p1")
      q = QueryHelpers.where_tenant(base_query(), ctx)
      # Two filters (org_id + project_id), neither a fail-closed `false`.
      assert length(q.wheres) == 2
      refute Enum.any?(q.wheres, &(&1.expr == false))
    end

    test "where_tenant/3 raises for an org-less AUTHENTICATED tenant context" do
      ctx = Context.build(user_id: "u1", org_id: nil, project_id: "p1", authenticated: true)

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        QueryHelpers.where_tenant(base_query(), ctx)
      end
    end
  end

  describe "Sanctum chokepoints reject an org-less context" do
    test "Sanctum.Permission.{get,set,list,delete} reject an org-less context" do
      ctx = Context.build(user_id: "u1", namespace: "u1", org_id: nil, authenticated: true)

      assert_raise Sanctum.UnauthorizedError, fn -> Sanctum.Permission.get(ctx, "subj") end

      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Permission.set(ctx, "subj", ["execute"])
      end

      assert_raise Sanctum.UnauthorizedError, fn -> Sanctum.Permission.list(ctx) end
      assert_raise Sanctum.UnauthorizedError, fn -> Sanctum.Permission.delete(ctx, "subj") end
      # has?/check_permission go through get/2 → inherit the chokepoint.
      assert_raise Sanctum.UnauthorizedError, fn ->
        Sanctum.Permission.has?(ctx, "subj", "execute")
      end
    end

    test "Arca.Storage.tenant_segments/1 fails closed for an org-less context" do
      ctx = Context.build(user_id: "u1", namespace: "u1", org_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved org_id is required/, fn ->
        Arca.Storage.tenant_segments(ctx)
      end
    end

    test "a context with a real org passes the chokepoint (tenant_segments)" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          org_id: "org_alpha",
          project_id: "proj_1",
          authenticated: true
        )

      assert ["org_alpha", "proj_1"] = Arca.Storage.tenant_segments(ctx)
    end
  end

  describe "Arca.Storage.tenant_segments/1 — seeded local org" do
    test "uses the seeded local org literally (single-user layout, namespace not in path)" do
      ctx =
        Context.build(
          user_id: "u1",
          namespace: "u1",
          org_id: "local",
          project_id: "default",
          authenticated: true
        )

      assert ["local", "default"] = Arca.Storage.tenant_segments(ctx)
    end
  end
end
