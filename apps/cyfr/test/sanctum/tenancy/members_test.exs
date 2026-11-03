# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.MembersTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Members}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    {:ok, athanor} =
      Athanors.create(%{
        name: "Test Athanor",
        slug: "test-athanor-#{System.unique_integer([:positive])}",
        owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
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

    test "writes no platform grant: the installation's first person's admission is its one writer" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:error, :no_athanor} = Members.create(%{user_id: uid, scope: "platform"})
      assert {:ok, []} = Members.list_by_user(uid)
      refute Sanctum.Tenancy.platform_admin?(uid)
    end

    test "rejects an invalid scope", %{athanor: athanor} do
      assert {:error, {:invalid, %{scope: [_ | _]}}} =
               Members.create(attrs(athanor.id, %{scope: "superadmin"}))
    end

    test "an athanor row with no athanor is refused before any query runs" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:error, :no_athanor} = Members.create(%{user_id: uid, scope: "athanor"})
    end

    test "rejects a duplicate assignment", %{athanor: athanor} do
      attrs = attrs(athanor.id)
      assert {:ok, _} = Members.create(attrs)
      # The assignment index is the one refusal a caller acts on rather
      # than reports: `ensure/2` re-reads the row it raced for.
      assert {:error, :conflict} = Members.create(attrs)
    end

    test "requires an existing athanor row" do
      assert {:error, :unknown_athanor} = Members.create(attrs("ath_does_not_exist"))
    end
  end

  describe "ensure/2" do
    test "is idempotent — repeated calls return the same row", %{athanor: athanor} do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, first} = Members.ensure(uid, scope: "athanor", athanor_id: athanor.id)
      assert {:ok, again} = Members.ensure(uid, scope: "athanor", athanor_id: athanor.id)
      assert first.id == again.id
      assert [_one] = rows!(Members.list_by_user(uid))
    end

    test "grants no platform seat" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:error, :no_athanor} = Members.ensure(uid, scope: "platform")
      assert {:ok, []} = Members.list_by_user(uid)
      refute Sanctum.Tenancy.platform_admin?(uid)
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
      assert {:ok, found} = Sanctum.TestContext.membership(mem.id)
      assert found.id == mem.id
    end

    test "returns not_found" do
      assert {:error, :not_found} = Sanctum.TestContext.membership("mem_nonexistent")
    end
  end

  describe "list_by_athanor/2" do
    test "lists memberships for an athanor as display rows, paged", %{athanor: athanor} do
      {:ok, _} = Members.create(attrs(athanor.id))
      {:ok, _} = Members.create(attrs(athanor.id))
      mems = rows!(Members.list_by_athanor(athanor.id))
      assert length(mems) >= 2
      assert Enum.all?(mems, &Map.has_key?(&1, :display_name))

      [first | _] = mems
      assert [^first] = rows!(Members.list_by_athanor(athanor.id, limit: 1))
      assert rows!(Members.list_by_athanor(athanor.id, limit: 1, offset: 1)) != [first]
    end
  end

  describe "list_by_user/2" do
    test "lists memberships for a user", %{athanor: athanor} do
      user_id = "user_" <> Ecto.UUID.generate()
      {:ok, _} = Members.create(attrs(athanor.id, %{user_id: user_id}))
      assert rows!(Members.list_by_user(user_id)) != []
    end
  end

  defp rows!({:ok, rows}), do: rows
end
