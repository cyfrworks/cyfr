# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.MembershipsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Orgs, Memberships}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, org} = Orgs.create(%{name: "Test Org", slug: "test-org"})
    {:ok, org: org}
  end

  defp org_attrs(org_id, overrides \\ %{}) do
    Map.merge(
      %{user_id: "user_" <> Ecto.UUID.generate(), scope: "org", org_id: org_id},
      overrides
    )
  end

  describe "create/1" do
    test "creates an org-scope membership", %{org: org} do
      assert {:ok, mem} = Memberships.create(org_attrs(org.id))
      assert mem.scope == "org"
      assert mem.org_id == org.id
      assert String.starts_with?(mem.id, "mem_")
    end

    test "creates a platform-scope membership with no org", %{org: _org} do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, mem} = Memberships.create(%{user_id: uid, scope: "platform"})
      assert mem.scope == "platform"
      assert mem.org_id == nil
    end

    test "rejects an invalid scope", %{org: org} do
      assert {:error, changeset} = Memberships.create(org_attrs(org.id, %{scope: "superadmin"}))
      assert %{scope: [_ | _]} = errors_on(changeset)
    end

    test "requires org_id for org scope" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:error, changeset} = Memberships.create(%{user_id: uid, scope: "org"})
      assert %{org_id: [_ | _]} = errors_on(changeset)
    end

    test "requires org_id and project_id for project scope", %{org: org} do
      uid = "user_" <> Ecto.UUID.generate()

      assert {:error, changeset} =
               Memberships.create(%{user_id: uid, scope: "project", org_id: org.id})

      assert %{project_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects a duplicate assignment", %{org: org} do
      attrs = org_attrs(org.id)
      assert {:ok, _} = Memberships.create(attrs)
      assert {:error, changeset} = Memberships.create(attrs)
      assert %{user_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "ensure/2" do
    test "is idempotent — repeated calls return the same row" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, first} = Memberships.ensure(uid, scope: "platform")
      assert {:ok, again} = Memberships.ensure(uid, scope: "platform")
      assert first.id == again.id
      assert [_one] = Memberships.list_by_user(uid)
    end
  end

  describe "get/1" do
    test "returns membership by id", %{org: org} do
      {:ok, mem} = Memberships.create(org_attrs(org.id))
      assert {:ok, found} = Memberships.get(mem.id)
      assert found.id == mem.id
    end

    test "returns not_found" do
      assert {:error, :not_found} = Memberships.get("mem_nonexistent")
    end
  end

  describe "get_by_user_and_org/2" do
    test "returns membership", %{org: org} do
      attrs = org_attrs(org.id)
      {:ok, mem} = Memberships.create(attrs)
      assert {:ok, found} = Memberships.get_by_user_and_org(attrs.user_id, org.id)
      assert found.id == mem.id
    end
  end

  describe "remove/1" do
    test "deletes a membership", %{org: org} do
      {:ok, mem} = Memberships.create(org_attrs(org.id))
      assert {:ok, _} = Memberships.remove(mem)
      assert {:error, :not_found} = Memberships.get(mem.id)
    end
  end

  describe "list_by_org/2" do
    test "lists memberships for an org", %{org: org} do
      {:ok, _} = Memberships.create(org_attrs(org.id))
      {:ok, _} = Memberships.create(org_attrs(org.id))
      mems = Memberships.list_by_org(org.id)
      assert length(mems) >= 2
    end
  end

  describe "list_by_user/2" do
    test "lists memberships for a user", %{org: org} do
      user_id = "user_" <> Ecto.UUID.generate()
      {:ok, _} = Memberships.create(org_attrs(org.id, %{user_id: user_id}))
      assert Memberships.list_by_user(user_id) != []
    end
  end

  describe "cascading delete" do
    test "deleting org removes memberships", %{org: org} do
      {:ok, mem} = Memberships.create(org_attrs(org.id))
      {:ok, _} = Orgs.delete(org)
      assert {:error, :not_found} = Memberships.get(mem.id)
    end
  end

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
