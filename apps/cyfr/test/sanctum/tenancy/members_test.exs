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
    test "lists memberships for an athanor as display rows, paged", %{athanor: athanor} do
      {:ok, _} = Members.create(attrs(athanor.id))
      {:ok, _} = Members.create(attrs(athanor.id))
      mems = Members.list_by_athanor(athanor.id)
      assert length(mems) >= 2
      assert Enum.all?(mems, &Map.has_key?(&1, :display_name))

      [first | _] = mems
      assert [^first] = Members.list_by_athanor(athanor.id, limit: 1)
      assert Members.list_by_athanor(athanor.id, limit: 1, offset: 1) != [first]
    end
  end

  describe "list_by_user/2" do
    test "lists memberships for a user", %{athanor: athanor} do
      user_id = "user_" <> Ecto.UUID.generate()
      {:ok, _} = Members.create(attrs(athanor.id, %{user_id: user_id}))
      assert Members.list_by_user(user_id) != []
    end
  end

  defp person(n) do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|mem-#{n}",
        provider: "github",
        email: "mem#{n}@example.com",
        verified: true
      })

    user
  end

  describe "add/3 by user id" do
    test "seats a known active person; refuses an unknown or denied id", %{athanor: athanor} do
      n = System.unique_integer([:positive])
      known = person(n)

      assert {:ok, :added} = Members.add(athanor, [user_id: known.id], "system")
      assert Members.member?(known.id, athanor.id)

      assert {:error, :unknown_user} =
               Members.add(athanor, [user_id: "github|https://github.com|nobody-#{n}"], "system")

      denied = person(n + 1)
      {:ok, _} = Sanctum.Tenancy.Users.deny(denied)
      assert {:error, :unknown_user} = Members.add(athanor, [user_id: denied.id], "system")
      refute Members.member?(denied.id, athanor.id)
    end

    test "the member cap counts invitations as seats", %{athanor: athanor} do
      prev = Application.get_env(:cyfr, :caps)
      Application.put_env(:cyfr, :caps, max_members_per_group: 2)
      on_exit(fn -> if prev, do: Application.put_env(:cyfr, :caps, prev), else: Application.delete_env(:cyfr, :caps) end)

      n = System.unique_integer([:positive])
      # the group's creator is not seated by create/1 here, so two seats are free
      assert {:ok, :invited} = Members.add(athanor, [email: "one-#{n}@example.com"], "system")
      assert {:ok, :invited} = Members.add(athanor, [email: "two-#{n}@example.com"], "system")

      assert {:error, {:limit_reached, :max_members_per_group, 2}} =
               Members.add(athanor, [user_id: person(n).id], "system")
    end
  end

  describe "activate_invited/1" do
    test "activates every invitation for the verified email in one pass and consumes the email",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      email = "invitee#{n}@example.com"
      {:ok, :invited} = Members.add(athanor, [email: email], "system")

      {:ok, other} =
        Athanors.create(%{kind: "group", name: "Other", slug: "other-#{n}", created_by: "system"})

      {:ok, :invited} = Members.add(other, [email: email], "system")

      user = person(n)
      {:ok, user} = Sanctum.Tenancy.Users.upsert_from_provider(%{id: user.id, provider: "github", email: email, verified: true})

      Phoenix.PubSub.subscribe(Emissary.PubSub, Members.topic(user.id))
      assert {:ok, 2} = Members.activate_invited(user)

      assert Members.member?(user.id, athanor.id)
      assert Members.member?(user.id, other.id)
      assert_receive {:membership_changed, %{change: :joined}}

      # the invitations are gone as invitations, and the seat carries no email
      rows = Members.list_by_athanor(athanor.id)
      refute Enum.any?(rows, &(&1.status == "invited"))
      assert Enum.any?(rows, &(&1.user_id == user.id and &1.status == "active"))

      # a second activation finds nothing to do
      assert {:ok, 0} = Members.activate_invited(user)
    end

    test "an invitation for an athanor the person already belongs to is dropped, not duplicated",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      email = "dup#{n}@example.com"
      user = person(n)
      {:ok, user} = Sanctum.Tenancy.Users.upsert_from_provider(%{id: user.id, provider: "github", email: email, verified: true})
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      # an invite written by email before anyone noticed the person is here
      {:ok, _} =
        Members.create(%{email: email, scope: "athanor", status: "invited", athanor_id: athanor.id})

      assert {:ok, 0} = Members.activate_invited(user)
      rows = Enum.filter(Members.list_by_athanor(athanor.id), &(&1.user_id == user.id or &1.email == email))
      assert [%{status: "active"}] = rows
    end
  end

  describe "remove_member/2" do
    test "the last active member leaving a group archives it; Home never", %{athanor: athanor} do
      n = System.unique_integer([:positive])
      user = person(n)
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      :ok = Members.remove_member(athanor, user_id: user.id)
      assert {:ok, %{status: "archived"}} = Athanors.get(athanor.id)

      home = Athanors.home!()
      {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: home.id)
      :ok = Members.remove_member(home, user_id: user.id)
      assert {:ok, %{status: "active"}} = Athanors.get(home.id)
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
