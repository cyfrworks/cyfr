# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.MembersTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Members}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, athanor} =
      Athanors.create(%{
        kind: "group",
        name: "Test Group",
        slug: "test-group-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    {:ok, athanor: athanor}
  end

  defp attrs(athanor_id, overrides \\ %{}) do
    Map.merge(
      %{user_id: "user_" <> Ecto.UUID.generate(), scope: "athanor", athanor_id: athanor_id},
      overrides
    )
  end

  describe "create/1" do
    test "creates an athanor membership", %{athanor: athanor} do
      assert {:ok, mem} = Members.create(attrs(athanor.id))
      assert mem.scope == "athanor"
      assert mem.athanor_id == athanor.id
      assert String.starts_with?(mem.id, "mem_")
    end

    test "creates a platform membership with no athanor" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, mem} = Members.create(%{user_id: uid, scope: "platform"})
      assert mem.scope == "platform"
      assert mem.athanor_id == nil
    end

    test "rejects an invalid scope", %{athanor: athanor} do
      assert {:error, changeset} = Members.create(attrs(athanor.id, %{scope: "superadmin"}))
      assert %{scope: [_ | _]} = errors_on(changeset)
    end

    test "requires an athanor for the athanor scope" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:error, changeset} = Members.create(%{user_id: uid, scope: "athanor"})
      assert %{athanor_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects a duplicate assignment", %{athanor: athanor} do
      attrs = attrs(athanor.id)
      assert {:ok, _} = Members.create(attrs)
      assert {:error, changeset} = Members.create(attrs)
      assert %{user_id: [_ | _]} = errors_on(changeset)
    end

    test "requires an existing athanor row" do
      assert {:error, changeset} = Members.create(attrs("ath_does_not_exist"))
      assert %{athanor_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "ensure/2" do
    test "is idempotent — repeated calls return the same row" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, first} = Members.ensure(uid, scope: "platform")
      assert {:ok, again} = Members.ensure(uid, scope: "platform")
      assert first.id == again.id
      assert [_one] = Members.list_by_user(uid)
    end

    test "athanor memberships key on the athanor", %{athanor: athanor} do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, first} = Members.ensure(uid, scope: "athanor", athanor_id: athanor.id)
      assert {:ok, again} = Members.ensure(uid, scope: "athanor", athanor_id: athanor.id)
      assert first.id == again.id
    end
  end

  describe "get/1" do
    test "returns membership by id", %{athanor: athanor} do
      {:ok, mem} = Members.create(attrs(athanor.id))
      assert {:ok, found} = Members.get(mem.id)
      assert found.id == mem.id
    end

    test "returns not_found" do
      assert {:error, :not_found} = Members.get("mem_nonexistent")
    end
  end

  describe "remove/1" do
    test "deletes a membership", %{athanor: athanor} do
      {:ok, mem} = Members.create(attrs(athanor.id))
      assert {:ok, _} = Members.remove(mem)
      assert {:error, :not_found} = Members.get(mem.id)
    end
  end

  describe "list_by_athanor/2" do
    test "lists memberships for an athanor", %{athanor: athanor} do
      {:ok, _} = Members.create(attrs(athanor.id))
      {:ok, _} = Members.create(attrs(athanor.id))
      mems = Members.list_by_athanor(athanor.id)
      assert length(mems) >= 2
    end
  end

  describe "list_by_user/2" do
    test "lists memberships for a user", %{athanor: athanor} do
      user_id = "user_" <> Ecto.UUID.generate()
      {:ok, _} = Members.create(attrs(athanor.id, %{user_id: user_id}))
      assert Members.list_by_user(user_id) != []
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
