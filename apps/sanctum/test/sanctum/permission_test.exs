defmodule Sanctum.PermissionTest do
  use ExUnit.Case, async: false

  alias Sanctum.Permission
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    {:ok, ctx: Context.local()}
  end

  describe "set/3 and get/2" do
    test "sets and gets permissions for a subject", %{ctx: ctx} do
      assert :ok = Permission.set(ctx, "user@example.com", ["execute", "read"])
      assert {:ok, ["execute", "read"]} = Permission.get(ctx, "user@example.com")
    end

    test "returns empty list for non-existent subject", %{ctx: ctx} do
      assert {:ok, []} = Permission.get(ctx, "nonexistent@example.com")
    end

    test "overwrites existing permissions", %{ctx: ctx} do
      assert :ok = Permission.set(ctx, "user@example.com", ["execute"])
      assert :ok = Permission.set(ctx, "user@example.com", ["read", "write"])
      assert {:ok, ["read", "write"]} = Permission.get(ctx, "user@example.com")
    end
  end

  describe "has?/3" do
    test "returns true when subject has permission", %{ctx: ctx} do
      Permission.set(ctx, "user@example.com", ["execute", "read"])

      assert Permission.has?(ctx, "user@example.com", "execute")
      assert Permission.has?(ctx, "user@example.com", "read")
    end

    test "returns false when subject lacks permission", %{ctx: ctx} do
      Permission.set(ctx, "user@example.com", ["execute"])

      refute Permission.has?(ctx, "user@example.com", "write")
    end

    test "returns true for wildcard permission", %{ctx: ctx} do
      Permission.set(ctx, "admin@example.com", ["*"])

      assert Permission.has?(ctx, "admin@example.com", "execute")
      assert Permission.has?(ctx, "admin@example.com", "any_permission")
    end

    test "returns false for non-existent subject (fail-closed)", %{ctx: ctx} do
      refute Permission.has?(ctx, "nobody@example.com", "execute")
    end
  end

  describe "check_permission/3" do
    test "returns {:ok, true} when permission is granted", %{ctx: ctx} do
      Permission.set(ctx, "user@example.com", ["execute", "read"])

      assert {:ok, true} = Permission.check_permission(ctx, "user@example.com", "execute")
      assert {:ok, true} = Permission.check_permission(ctx, "user@example.com", "read")
    end

    test "returns {:ok, false} when permission is denied", %{ctx: ctx} do
      Permission.set(ctx, "user@example.com", ["execute"])

      assert {:ok, false} = Permission.check_permission(ctx, "user@example.com", "write")
    end

    test "returns {:ok, true} for wildcard permission", %{ctx: ctx} do
      Permission.set(ctx, "admin@example.com", ["*"])

      assert {:ok, true} = Permission.check_permission(ctx, "admin@example.com", "any_permission")
    end

    test "returns {:ok, false} for non-existent subject", %{ctx: ctx} do
      assert {:ok, false} = Permission.check_permission(ctx, "nonexistent@example.com", "execute")
    end
  end

  describe "list/1" do
    test "returns empty list when no permissions exist", %{ctx: ctx} do
      assert {:ok, []} = Permission.list(ctx)
    end

    test "returns all subjects with their permissions", %{ctx: ctx} do
      Permission.set(ctx, "alice@example.com", ["execute"])
      Permission.set(ctx, "bob@example.com", ["read", "write"])

      {:ok, entries} = Permission.list(ctx)

      assert length(entries) == 2
      assert Enum.any?(entries, fn e -> e.subject == "alice@example.com" end)
      assert Enum.any?(entries, fn e -> e.subject == "bob@example.com" end)
    end
  end

  describe "delete/2" do
    test "removes permissions for a subject", %{ctx: ctx} do
      Permission.set(ctx, "user@example.com", ["execute"])
      assert {:ok, ["execute"]} = Permission.get(ctx, "user@example.com")

      assert :ok = Permission.delete(ctx, "user@example.com")
      assert {:ok, []} = Permission.get(ctx, "user@example.com")
    end
  end

  describe "get_for_resource/2" do
    test "gets permissions for resource reference", %{ctx: ctx} do
      Permission.set(ctx, "resource:components/my-component:1.0", ["read", "execute"])

      assert {:ok, ["read", "execute"]} = Permission.get_for_resource(ctx, "components/my-component:1.0")
    end

    test "returns empty list for non-existent resource", %{ctx: ctx} do
      assert {:ok, []} = Permission.get_for_resource(ctx, "nonexistent/resource:1.0")
    end
  end

  describe "org scope isolation" do
    test "org permissions are isolated from personal permissions", %{ctx: ctx} do
      org_ctx = %Context{
        user_id: "user_123",
        org_id: "my-org",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      # Set same subject in both contexts
      assert :ok = Permission.set(ctx, "user@example.com", ["execute"])
      assert :ok = Permission.set(org_ctx, "user@example.com", ["read", "write"])

      # Values should be different based on context
      assert {:ok, ["execute"]} = Permission.get(ctx, "user@example.com")
      assert {:ok, ["read", "write"]} = Permission.get(org_ctx, "user@example.com")
    end

    test "different orgs have isolated permissions" do
      org1_ctx = %Context{
        user_id: "user_123",
        org_id: "org_one",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      org2_ctx = %Context{
        user_id: "user_123",
        org_id: "org_two",
        permissions: MapSet.new([:*]),
        scope: :org,
        auth_method: :oidc,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      assert :ok = Permission.set(org1_ctx, "user@example.com", ["admin"])
      assert :ok = Permission.set(org2_ctx, "user@example.com", ["read"])

      assert {:ok, ["admin"]} = Permission.get(org1_ctx, "user@example.com")
      assert {:ok, ["read"]} = Permission.get(org2_ctx, "user@example.com")
    end
  end

  describe "data integrity" do
    test "multiple rapid writes don't corrupt data", %{ctx: ctx} do
      for i <- 1..10 do
        assert :ok = Permission.set(ctx, "user#{i}@example.com", ["execute"])
      end

      {:ok, entries} = Permission.list(ctx)
      assert length(entries) == 10
    end
  end
end
