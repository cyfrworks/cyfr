defmodule SanctumArx.MembershipsTest do
  use ExUnit.Case, async: false

  alias SanctumArx.{Orgs, Memberships}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original_edition = Application.get_env(:cyfr, :edition)
    Application.put_env(:cyfr, :edition, :arx)

    on_exit(fn ->
      if original_edition,
        do: Application.put_env(:cyfr, :edition, original_edition),
        else: Application.delete_env(:cyfr, :edition)
    end)

    {:ok, org} = Orgs.create(%{name: "Test Org", slug: "test-org", plan: "free"})
    {:ok, org: org}
  end

  defp valid_membership_attrs(org_id, overrides \\ %{}) do
    Map.merge(
      %{user_id: "user_" <> Ecto.UUID.generate(), org_id: org_id, role: "member"},
      overrides
    )
  end

  describe "create/1" do
    test "creates a membership", %{org: org} do
      assert {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      assert mem.role == "member"
      assert mem.org_id == org.id
      assert String.starts_with?(mem.id, "mem_")
      assert mem.invited_at != nil
    end

    test "rejects invalid role", %{org: org} do
      assert {:error, changeset} =
               Memberships.create(valid_membership_attrs(org.id, %{role: "superadmin"}))

      assert %{role: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate user+org", %{org: org} do
      attrs = valid_membership_attrs(org.id)
      assert {:ok, _} = Memberships.create(attrs)
      assert {:error, changeset} = Memberships.create(attrs)
      assert %{user_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "accept/1" do
    test "sets accepted_at", %{org: org} do
      {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      assert mem.accepted_at == nil
      assert {:ok, accepted} = Memberships.accept(mem)
      assert accepted.accepted_at != nil
    end
  end

  describe "get/1" do
    test "returns membership by id", %{org: org} do
      {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      assert {:ok, found} = Memberships.get(mem.id)
      assert found.id == mem.id
    end

    test "returns not_found" do
      assert {:error, :not_found} = Memberships.get("mem_nonexistent")
    end
  end

  describe "get_by_user_and_org/2" do
    test "returns membership", %{org: org} do
      attrs = valid_membership_attrs(org.id)
      {:ok, mem} = Memberships.create(attrs)
      assert {:ok, found} = Memberships.get_by_user_and_org(attrs.user_id, org.id)
      assert found.id == mem.id
    end
  end

  describe "update_role/2" do
    test "updates the role", %{org: org} do
      {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      assert {:ok, updated} = Memberships.update_role(mem, "admin")
      assert updated.role == "admin"
    end
  end

  describe "remove/1" do
    test "deletes a membership", %{org: org} do
      {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      assert {:ok, _} = Memberships.remove(mem)
      assert {:error, :not_found} = Memberships.get(mem.id)
    end
  end

  describe "list_by_org/2" do
    test "lists memberships for an org", %{org: org} do
      {:ok, _} = Memberships.create(valid_membership_attrs(org.id))
      {:ok, _} = Memberships.create(valid_membership_attrs(org.id))
      mems = Memberships.list_by_org(org.id)
      assert length(mems) >= 2
    end
  end

  describe "list_by_user/2" do
    test "lists memberships for a user", %{org: org} do
      user_id = "user_" <> Ecto.UUID.generate()
      {:ok, _} = Memberships.create(valid_membership_attrs(org.id, %{user_id: user_id}))
      mems = Memberships.list_by_user(user_id)
      assert length(mems) >= 1
    end
  end

  describe "user_role/2" do
    test "returns the role", %{org: org} do
      attrs = valid_membership_attrs(org.id, %{role: "owner"})
      {:ok, _} = Memberships.create(attrs)
      assert {:ok, "owner"} = Memberships.user_role(attrs.user_id, org.id)
    end

    test "returns not_found for non-member", %{org: org} do
      assert {:error, :not_found} = Memberships.user_role("user_nobody", org.id)
    end
  end

  describe "cascading delete" do
    test "deleting org removes memberships", %{org: org} do
      {:ok, mem} = Memberships.create(valid_membership_attrs(org.id))
      {:ok, _} = Orgs.delete(org)
      assert {:error, :not_found} = Memberships.get(mem.id)
    end
  end

  describe "edition gating" do
    test "returns feature_not_available in community mode", %{org: org} do
      Application.put_env(:cyfr, :edition, :core)
      assert {:error, :feature_not_available} = Memberships.create(valid_membership_attrs(org.id))
      assert {:error, :feature_not_available} = Memberships.get("mem_x")
      assert {:error, :feature_not_available} = Memberships.list_by_org(org.id)
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
