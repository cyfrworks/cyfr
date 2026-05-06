defmodule Sanctum.PermissiveTenantPolicyTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context
  alias Sanctum.PermissiveTenantPolicy

  describe "require_org/1 (Core)" do
    test "always returns :ok — Core has no org concept" do
      assert :ok = PermissiveTenantPolicy.require_org(Context.build(user_id: "u1"))
      assert :ok = PermissiveTenantPolicy.require_org(Context.build(user_id: "u1", org_id: nil))
      assert :ok = PermissiveTenantPolicy.require_org(Context.build(user_id: "u1", org_id: ""))

      assert :ok =
               PermissiveTenantPolicy.require_org(Context.build(user_id: "u1", org_id: "acme"))
    end
  end

  describe "verify/2 (Core)" do
    test ":platform scope bypasses tenant checks" do
      ctx = Context.build(user_id: "u1", scope: :platform)
      assert :ok = PermissiveTenantPolicy.verify(ctx, %{org_id: "any", project_id: "x"})
    end

    test "nil org_id is allowed (Core single-user)" do
      ctx = Context.build(user_id: "u1", org_id: nil)
      assert :ok = PermissiveTenantPolicy.verify(ctx, %{org_id: "any", project_id: "x"})
    end

    test "matching org/project pair returns :ok" do
      ctx = Context.build(user_id: "u1", org_id: "acme", project_id: "widgets")
      assert :ok = PermissiveTenantPolicy.verify(ctx, %{org_id: "acme", project_id: "widgets"})
    end

    test "mismatched org returns error" do
      ctx = Context.build(user_id: "u1", org_id: "acme", project_id: "widgets")

      assert {:error, "Unauthorized: tenant mismatch"} =
               PermissiveTenantPolicy.verify(ctx, %{org_id: "evil", project_id: "widgets"})
    end

    test "mismatched project returns error" do
      ctx = Context.build(user_id: "u1", org_id: "acme", project_id: "widgets")

      assert {:error, "Unauthorized: tenant mismatch"} =
               PermissiveTenantPolicy.verify(ctx, %{org_id: "acme", project_id: "secrets"})
    end
  end
end
