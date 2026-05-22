# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantPolicyTest do
  use ExUnit.Case, async: true

  alias Sanctum.TenantPolicy
  alias Sanctum.Context

  describe "require_org/1" do
    test "rejects nil org_id" do
      ctx = %Context{user_id: "u1", org_id: nil}
      assert {:error, :missing_tenant} = TenantPolicy.require_org(ctx)
    end

    test "rejects empty-string org_id" do
      ctx = %Context{user_id: "u1", org_id: ""}
      assert {:error, :missing_tenant} = TenantPolicy.require_org(ctx)
    end

    test "accepts 'local' — it is a normal org gated by membership, not a special case" do
      ctx = %Context{user_id: "u1", org_id: "local"}
      assert :ok = TenantPolicy.require_org(ctx)
    end

    test "accepts any non-empty org_id" do
      ctx = %Context{user_id: "u1", org_id: "acme-corp"}
      assert :ok = TenantPolicy.require_org(ctx)
    end
  end

  describe "verify/2" do
    test ":platform scope bypasses (cross-tenant ops e.g. retention sweeps)" do
      ctx = Context.build(user_id: "u1", scope: :platform)
      assert :ok = TenantPolicy.verify(ctx, %{org_id: "any", project_id: "x"})
    end

    test "rejects nil org_id even outside :platform scope" do
      ctx = %Context{user_id: "u1", org_id: nil}

      assert {:error, "Unauthorized: a resolved org_id is required"} =
               TenantPolicy.verify(ctx, %{org_id: "acme", project_id: "x"})
    end

    test "enforces tenant equality when org_id is set" do
      ctx = Context.build(user_id: "u1", org_id: "acme", project_id: "widgets")

      # Match → :ok
      assert :ok = TenantPolicy.verify(ctx, %{org_id: "acme", project_id: "widgets"})

      # Mismatch → error
      assert {:error, "Unauthorized: tenant mismatch"} =
               TenantPolicy.verify(ctx, %{org_id: "evil", project_id: "widgets"})
    end
  end
end
