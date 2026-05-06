defmodule Arca.PermissionStorageTest do
  use ExUnit.Case, async: false

  alias Arca.PermissionStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    org_id = ctx.org_id

    {:ok, org_id: org_id}
  end

  describe "set_permissions/4 and get_permissions/3" do
    test "stores and retrieves permissions", %{org_id: org_id} do
      perms = "[\"execute\",\"component:read\",\"component:write\"]"
      :ok = PermissionStorage.set_permissions("user_1", perms, "project", org_id)

      assert {:ok, ^perms} = PermissionStorage.get_permissions("user_1", "project", org_id)
    end

    test "upserts on conflict", %{org_id: org_id} do
      :ok = PermissionStorage.set_permissions("user_upsert", "[\"execute\"]", "project", org_id)

      :ok =
        PermissionStorage.set_permissions(
          "user_upsert",
          "[\"execute\",\"admin\"]",
          "project",
          org_id
        )

      {:ok, perms} = PermissionStorage.get_permissions("user_upsert", "project", org_id)
      assert perms == "[\"execute\",\"admin\"]"
    end

    test "returns not_found for missing subject", %{org_id: org_id} do
      assert {:error, :not_found} = PermissionStorage.get_permissions("nobody", "project", org_id)
    end
  end

  describe "list_permissions/2" do
    test "lists all subjects with permissions", %{org_id: org_id} do
      :ok = PermissionStorage.set_permissions("alice", "[\"admin\"]", "project", org_id)
      :ok = PermissionStorage.set_permissions("bob", "[\"execute\"]", "project", org_id)

      {:ok, entries} = PermissionStorage.list_permissions("project", org_id)
      subjects = Enum.map(entries, & &1.subject)
      assert "alice" in subjects
      assert "bob" in subjects
    end

    test "returns empty list when no permissions", %{org_id: org_id} do
      {:ok, entries} = PermissionStorage.list_permissions("empty_scope", org_id)
      assert entries == []
    end
  end

  describe "delete_permissions/3" do
    test "deletes permissions for a subject", %{org_id: org_id} do
      :ok = PermissionStorage.set_permissions("to_delete", "[\"execute\"]", "project", org_id)
      :ok = PermissionStorage.delete_permissions("to_delete", "project", org_id)

      assert {:error, :not_found} =
               PermissionStorage.get_permissions("to_delete", "project", org_id)
    end

    test "succeeds for nonexistent subject", %{org_id: org_id} do
      assert :ok = PermissionStorage.delete_permissions("nope", "project", org_id)
    end
  end

  describe "tenant isolation" do
    test "different org_ids have independent permissions" do
      :ok =
        PermissionStorage.set_permissions("shared_user", "[\"admin\"]", "project", "org_alpha")

      :ok =
        PermissionStorage.set_permissions("shared_user", "[\"read_only\"]", "project", "org_beta")

      {:ok, perms_a} = PermissionStorage.get_permissions("shared_user", "project", "org_alpha")
      {:ok, perms_b} = PermissionStorage.get_permissions("shared_user", "project", "org_beta")

      assert perms_a == "[\"admin\"]"
      assert perms_b == "[\"read_only\"]"
    end
  end
end
