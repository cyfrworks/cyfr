# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.StrictAuthorizeTenantTest do
  @moduledoc """
  F5: `Sanctum.Context.authorize/3` is the authoritative tenant check. A
  cross-tenant record must be denied *at authorize/3* (not only later by the
  storage backstop) for every recognized resource shape.
  """
  use ExUnit.Case, async: true

  alias Sanctum.Context

  setup do
    ctx =
      Context.build(
        user_id: "u1",
        namespace: "u1",
        org_id: "org_a",
        project_id: "default",
        scope: :project,
        permissions: [:*],
        authenticated: true
      )

    %{ctx: ctx}
  end

  describe "authorize/3 enforces the record's tenant under the strict policy" do
    test "{:tenant, record} — same org passes, cross-org denied", %{ctx: ctx} do
      assert :ok =
               Context.authorize(ctx, :read, {:tenant, %{org_id: "org_a", project_id: "default"}})

      assert {:error, _} =
               Context.authorize(ctx, :read, {:tenant, %{org_id: "org_b", project_id: "default"}})
    end

    test "{:execution, record} — cross-org denied before the ownership check", %{ctx: ctx} do
      # ctx owns it (same user_id) and holds :* — but a foreign org must still
      # be rejected by verify_tenant, which runs before ownership.
      assert {:error, _} =
               Context.authorize(ctx, :read, {:execution, %{user_id: "u1", org_id: "org_b"}})

      assert :ok =
               Context.authorize(ctx, :read, {:execution, %{user_id: "u1", org_id: "org_a"}})
    end

    test "{:owned, record} — cross-org denied", %{ctx: ctx} do
      assert {:error, _} =
               Context.authorize(ctx, :read, {:owned, %{user_id: "u1", org_id: "org_b"}})
    end

    test "permission-only (nil) — org-less context denied by tenant presence" do
      orgless =
        Context.build(
          user_id: "u2",
          namespace: "u2",
          org_id: nil,
          scope: :project,
          permissions: [:*],
          authenticated: true
        )

      # An explicit org-less context is rejected by the tenant policy as
      # missing_tenant.
      assert orgless.org_id == nil
      assert {:error, _} = Context.authorize(orgless, :read, nil)
    end

    test "unauthenticated context is always denied", %{ctx: ctx} do
      assert {:error, _} =
               Context.authorize(
                 %{ctx | authenticated: false},
                 :read,
                 {:tenant, %{org_id: "org_a"}}
               )
    end
  end
end
