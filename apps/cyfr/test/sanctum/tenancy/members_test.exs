# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.MembersTest do
  use ExUnit.Case, async: false

  alias Arca.ThreadSubscriptionStorage, as: Subs
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

  describe "revoke_platform/2" do
    # A person this server knows: a session is issued only to one.
    defp person_id do
      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|revoke-#{System.unique_integer([:positive])}",
          provider: "github",
          verified: true
        })

      user.id
    end

    defp session_for(user_id) do
      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: user_id,
            athanor_id: Sanctum.TestContext.athanor_id(),
            provider: "github",
            permissions: [:*],
            scope: :athanor,
            auth_method: :oidc,
            authenticated: true
          )
        )

      session.token
    end

    test "takes the grant and every session together, then announces the revocation" do
      uid = person_id()
      {:ok, _} = Members.ensure_platform(uid)
      token = session_for(uid)
      Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.sessions())

      assert :ok = Members.revoke_platform(uid)

      refute Sanctum.Tenancy.platform_admin?(uid)
      assert {:error, _} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
      assert_receive {:sessions_revoked, ^uid}
    end

    test "an absent grant ends no session and announces nothing" do
      uid = person_id()
      token = session_for(uid)
      Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.sessions())

      assert :ok = Members.revoke_platform(uid)

      assert {:ok, _} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
      refute_receive {:sessions_revoked, ^uid}, 100
    end
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
    test "is idempotent — repeated calls return the same row" do
      uid = "user_" <> Ecto.UUID.generate()
      assert {:ok, first} = Members.ensure(uid, scope: "platform")
      assert {:ok, again} = Members.ensure(uid, scope: "platform")
      assert first.id == again.id
      assert [_one] = rows!(Members.list_by_user(uid))
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

  # A context focused on the athanor as this person — what a follow is written through.
  defp follow_actor(athanor_id, user_id),
    do: %{Cyfr.Actor.in_athanor(athanor_id) | user_id: user_id}

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
      prev = Application.get_env(:sanctum, :caps)
      Application.put_env(:sanctum, :caps, max_members_per_group: 2)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:sanctum, :caps, prev),
          else: Application.delete_env(:sanctum, :caps)
      end)

      n = System.unique_integer([:positive])
      # the group's creator is not seated by create/1 here, so two seats are free
      assert {:ok, :invited} = Members.add(athanor, [email: "one-#{n}@example.com"], "system")
      assert {:ok, :invited} = Members.add(athanor, [email: "two-#{n}@example.com"], "system")

      assert {:error, {:limit_reached, :max_members_per_group, 2}} =
               Members.add(athanor, [user_id: person(n).id], "system")
    end
  end

  describe "add/3 by email" do
    test "a proved address is seated, an unproven one is invited, a denied one is refused",
         %{athanor: athanor} do
      # Seating by email is a grant keyed on the address alone. `true` seats
      # the known person; `nil` (an issuer that never asserts the claim)
      # holds an invited row that a proving sign-in claims; `false` refuses.
      for {claim, expected} <- [{true, :seated}, {nil, :invited}, {false, :refused}] do
        n = System.unique_integer([:positive])
        email = "claim#{n}@example.com"

        {:ok, user} =
          Sanctum.Tenancy.Users.upsert_from_provider(%{
            id: "oidcc|https://idp.example|claim-#{n}",
            provider: "oidcc",
            email: email,
            verified: claim
          })

        case expected do
          :seated ->
            assert {:ok, _} = Members.add(athanor, [email: email], "system")
            assert Members.member?(user.id, athanor.id)

          :invited ->
            assert {:ok, :invited} = Members.add(athanor, [email: email], "system")
            refute Members.member?(user.id, athanor.id)

            assert Enum.any?(
                     rows!(Members.list_by_athanor(athanor.id)),
                     &(&1.status == "invited" and &1.email == email)
                   )

          :refused ->
            assert {:error, :email_unverified} = Members.add(athanor, [email: email], "system")
            refute Members.member?(user.id, athanor.id)
        end
      end
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

      # Known to the server already, under another address: the upsert
      # below moves that same identity onto the invited one.
      _known = person(n)

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|mem-#{n}",
          provider: "github",
          email: email,
          verified: true
        })

      Phoenix.PubSub.subscribe(Emissary.PubSub, Members.topic(user.id))
      assert {:ok, 2} = Members.activate_invited(user)

      assert Members.member?(user.id, athanor.id)
      assert Members.member?(user.id, other.id)
      assert_receive {:membership_changed, %{change: :joined}}

      # the invitations are gone as invitations, and the seat carries no email
      rows = rows!(Members.list_by_athanor(athanor.id))
      refute Enum.any?(rows, &(&1.status == "invited"))
      assert Enum.any?(rows, &(&1.user_id == user.id and &1.status == "active"))

      # a second activation finds nothing to do
      assert {:ok, 0} = Members.activate_invited(user)
    end

    test "an invitation for an athanor the person already belongs to is dropped, not duplicated",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      email = "dup#{n}@example.com"
      # Known to the server already, under another address: the upsert
      # below moves that same identity onto the invited one.
      _known = person(n)

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|mem-#{n}",
          provider: "github",
          email: email,
          verified: true
        })

      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      # an invite written by email before anyone noticed the person is here
      {:ok, _} =
        Members.create(%{
          email: email,
          scope: "athanor",
          status: "invited",
          athanor_id: athanor.id
        })

      assert {:ok, 0} = Members.activate_invited(user)

      rows =
        Enum.filter(
          rows!(Members.list_by_athanor(athanor.id)),
          &(&1.user_id == user.id or &1.email == email)
        )

      assert [%{status: "active"}] = rows
    end

    test "an unproven address claims no seat", %{athanor: athanor} do
      # An invited row is email-keyed, so activating it on an address the
      # provider never asserted hands the seat to whoever can get the IdP to
      # claim it. The door already refuses an exact email allowlist entry on
      # anything but `true`; a group seat is the same kind of grant.
      n = System.unique_integer([:positive])
      email = "unproven#{n}@example.com"
      {:ok, :invited} = Members.add(athanor, [email: email], "system")

      # Known to the server already, under a proven address of their own.
      _known = person(n)

      for claim <- [nil, false] do
        {:ok, user} =
          Sanctum.Tenancy.Users.upsert_from_provider(%{
            id: "github|https://github.com|mem-#{n}",
            provider: "oidcc",
            email: email,
            verified: claim
          })

        assert {:ok, 0} = Members.activate_invited(user)
        refute Members.member?(user.id, athanor.id)
      end

      # The seat is still held, so proving the address later still claims it.
      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|mem-#{n}",
          provider: "oidcc",
          email: email,
          verified: true
        })

      assert {:ok, 1} = Members.activate_invited(user)
      assert Members.member?(user.id, athanor.id)
    end
  end

  describe "remove_member/2" do
    test "the last active member leaving a group archives it", %{athanor: athanor} do
      n = System.unique_integer([:positive])
      user = person(n)
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      :ok = Members.remove_member(athanor, user_id: user.id)
      assert {:ok, %{status: "archived"}} = Athanors.get(athanor.id)
    end
  end

  # Thread follows must be removed when membership ends.
  describe "follows end with the seat" do
    test "remove_member/2 drops the leaver's follows and nobody else's", %{athanor: athanor} do
      n = System.unique_integer([:positive])
      leaver = person(n)
      stayer = person(n + 1)
      {:ok, :added} = Members.add(athanor, [user_id: leaver.id], "system")
      {:ok, :added} = Members.add(athanor, [user_id: stayer.id], "system")

      thread = "thread_#{n}"
      :ok = Subs.follow(follow_actor(athanor.id, leaver.id), thread, leaver.id)
      :ok = Subs.follow(follow_actor(athanor.id, stayer.id), thread, stayer.id)

      :ok = Members.remove_member(athanor, user_id: leaver.id)

      refute Subs.follows?(Cyfr.Actor.in_athanor(athanor.id), thread, leaver.id)
      assert Subs.follows?(Cyfr.Actor.in_athanor(athanor.id), thread, stayer.id)
    end

    test "a denial drops the follows in every athanor the person sat in", %{
      athanor: athanor
    } do
      n = System.unique_integer([:positive])
      user = person(n)

      {:ok, other} =
        Athanors.create(%{kind: "group", name: "Other", slug: "other-#{n}", created_by: "system"})

      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")
      {:ok, :added} = Members.add(other, [user_id: user.id], "system")

      :ok = Subs.follow(follow_actor(athanor.id, user.id), "thread_a_#{n}", user.id)
      :ok = Subs.follow(follow_actor(other.id, user.id), "thread_b_#{n}", user.id)

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)

      assert Subs.followed(follow_actor(athanor.id, user.id), user.id) == MapSet.new()
      assert Subs.followed(follow_actor(other.id, user.id), user.id) == MapSet.new()
    end

    test "a member who leaves and is added again starts unfollowed", %{athanor: athanor} do
      n = System.unique_integer([:positive])
      user = person(n)
      stayer = person(n + 1)
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")
      {:ok, :added} = Members.add(athanor, [user_id: stayer.id], "system")

      ctx = follow_actor(athanor.id, user.id)
      thread = "thread_#{n}"
      :ok = Subs.follow(ctx, thread, user.id)
      assert MapSet.member?(Subs.followed(ctx, user.id), thread)

      :ok = Members.remove_member(athanor, user_id: user.id)
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      assert Members.member?(user.id, athanor.id)
      assert Subs.followed(ctx, user.id) == MapSet.new()
    end
  end

  defp rows!({:ok, rows}), do: rows
end
