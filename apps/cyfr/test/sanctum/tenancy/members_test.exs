# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.MembersTest do
  use ExUnit.Case, async: false

  alias Arca.Schemas.{DeviceCertificate, PairedClient}
  alias Arca.ThreadSubscriptionStorage, as: Subs
  alias Sanctum.Tenancy.{Athanors, Members}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

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
      Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

      assert :ok = Members.revoke_platform(uid)

      refute Sanctum.Tenancy.platform_admin?(uid)
      assert {:error, _} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
      assert_receive %Cyfr.Bus.Session{kind: :revoked, user_id: ^uid}
    end

    test "an absent grant ends no session and announces nothing" do
      uid = person_id()
      token = session_for(uid)
      Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

      assert :ok = Members.revoke_platform(uid)

      assert {:ok, _} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
      refute_receive %Cyfr.Bus.Session{kind: :revoked, user_id: ^uid}, 100
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
    test "withdraws an invitation", %{athanor: athanor} do
      {:ok, invitation} =
        Members.create(%{
          email: "withdrawn-#{System.unique_integer([:positive])}@example.com",
          scope: "athanor",
          athanor_id: athanor.id,
          status: "invited"
        })

      assert {:ok, %{id: id, status: "invited"}} = Members.remove(invitation)
      assert id == invitation.id
      assert {:error, :not_found} = Members.get(invitation.id)
      assert {:error, :not_found} = Members.remove(invitation)
    end

    test "an active row is not an invitation: not found, and it stays", %{athanor: athanor} do
      {:ok, seat} = Members.create(attrs(athanor.id))
      assert {:error, :not_found} = Members.remove(seat)
      assert {:ok, %{status: "active"}} = Members.get(seat.id)
      assert Members.member?(seat.user_id, athanor.id)

      # A platform grant names no athanor and is never an invitation either.
      {:ok, grant} = Members.ensure_platform("user_" <> Ecto.UUID.generate())
      assert {:error, :not_found} = Members.remove(grant)
      assert {:ok, %{scope: "platform"}} = Members.get(grant.id)
    end

    test "an invitation claimed since it was read is the claimant's seat: not found, and the seat stands",
         %{athanor: athanor} do
      email = "claimed-#{System.unique_integer([:positive])}@example.com"
      user_id = "user_" <> Ecto.UUID.generate()

      {:ok, invitation} =
        Members.create(%{
          email: email,
          scope: "athanor",
          athanor_id: athanor.id,
          status: "invited"
        })

      {:ok, [_]} = Arca.Members.activate_invited(server(), user_id, email, DateTime.utc_now())
      assert Members.member?(user_id, athanor.id)

      assert {:error, :not_found} = Members.remove(invitation)
      assert Members.member?(user_id, athanor.id)
      assert {:ok, %{id: id, status: "active"}} = Members.get(invitation.id)
      assert id == invitation.id
    end
  end

  # A first sign-in claims an invitation by turning its row into the seat
  # in place, so a withdrawal that read the invitation can meet the seat
  # at its delete. The claim is run between the two, in this process.
  describe "a withdrawal racing the invitee's first sign-in" do
    test "an address claimed between the lookup and the delete: the seat stands and the withdraw is not found",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      email = "racing#{n}@example.com"
      {:ok, :invited} = Members.add(athanor, [email: email], "system")
      invitee = verified!("racing-#{n}", email)

      claim_after_lookup!(fn ->
        {:ok, 1} = Members.activate_invited(invitee)
        # The claimant's first session, bound to the seat they just took.
        session!(invitee.id, athanor.id)
      end)

      assert {:error, :not_found} = Members.remove_member(athanor, email: email)
      assert_received {:claimed, session}

      # Nothing is orphaned: the seat is the row the invitation became,
      # and what the claimant was issued for it still stands beside it.
      assert Members.member?(invitee.id, athanor.id)
      assert session?(session)

      assert [%{user_id: user_id, status: "active", email: ^email}] =
               Enum.filter(
                 rows!(Members.list_by_athanor(athanor.id)),
                 &(&1.user_id == invitee.id or &1.email == email)
               )

      assert user_id == invitee.id
    end

    test "an identifier claimed between the lookup and the delete: withdrawing the invitation is not found, and the holder stays",
         %{athanor: athanor} do
      id = identifier()
      {:ok, :invited} = Members.add(athanor, [identifier: id], "system")
      holder = remote!(id)

      claim_after_lookup!(fn ->
        {:ok, 1} = Members.activate_invited(holder)
        client = paired!(athanor.id, holder.id)
        {client, certificate!(athanor.id, holder.id, client)}
      end)

      assert {:error, :not_found} = Members.withdraw_invitation(athanor, identifier: id)
      assert_received {:claimed, {client, cert}}

      assert Members.member?(holder.id, athanor.id)
      assert standing(PairedClient, client) == "active"
      assert state(DeviceCertificate, cert) == "active"
      refute Enum.any?(rows!(Members.list_by_athanor(athanor.id)), &(&1.status == "invited"))
    end

    test "an identifier claimed between the lookup and the delete is removed through the leave",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      id = identifier()
      {:ok, :invited} = Members.add(athanor, [identifier: id], "system")
      {:ok, :added} = Members.add(athanor, [user_id: person(n).id], "system")
      holder = remote!(id)

      claim_after_lookup!(fn ->
        {:ok, 1} = Members.activate_invited(holder)
        client = paired!(athanor.id, holder.id)
        {client, certificate!(athanor.id, holder.id, client)}
      end)

      # Without the invitation-only form, the identifier names whoever
      # holds it once the invitation is gone, and they leave as any
      # removed member does.
      assert :ok = Members.remove_member(athanor, identifier: id)
      assert_received {:claimed, {client, cert}}

      refute Members.member?(holder.id, athanor.id)
      assert standing(PairedClient, client) == "revoked"
      assert state(DeviceCertificate, cert) == "revoked"
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

  describe "people_sharing/1" do
    test "a seat removed, and a stranger seated, after its first query never reach the answer" do
      alice = named!("Alice Caller")
      bob = named!("Bob Stays")
      carol = named!("Carol Never Shared")

      {:ok, group} =
        Athanors.create_group(bob.id, "Picker race #{System.unique_integer([:positive])}")

      {:ok, _} = Members.ensure(alice.id, scope: "athanor", athanor_id: group.id)
      assert Members.shared_athanor?(alice.id, bob.id)
      refute Members.shared_athanor?(alice.id, carol.id)

      # Alice leaves and Carol sits down right after the first statement
      # the read issues.
      after_first_query!(fn ->
        {Members.remove_member(group, user_id: alice.id),
         Members.ensure(carol.id, scope: "athanor", athanor_id: group.id)}
      end)

      assert {:ok, people} = Members.people_sharing(alice.id)
      assert_received {:changed, {:ok, {:ok, _carol_seat}}}

      # Alice and Carol never sat together, so Carol is never listed to
      # Alice: the answer is the room as it stood when Alice's seat was read.
      refute Members.shared_athanor?(alice.id, carol.id)
      assert Enum.map(people, & &1.user_id) == [bob.id]

      # Read again, the leave holds: Alice sits with nobody.
      assert {:ok, []} = Members.people_sharing(alice.id)
    end

    test "is one statement, however many rooms the person sits in" do
      alice = named!("Alice")
      bob = named!("Bob")
      carol = named!("Carol")

      {:ok, first} =
        Athanors.create_group(bob.id, "One read #{System.unique_integer([:positive])}")

      {:ok, second} =
        Athanors.create_group(carol.id, "One read #{System.unique_integer([:positive])}")

      for group <- [first, second],
          do: {:ok, _} = Members.ensure(alice.id, scope: "athanor", athanor_id: group.id)

      assert {{:ok, people}, 1} = counting_queries(fn -> Members.people_sharing(alice.id) end)
      assert Enum.map(people, & &1.user_id) == [bob.id, carol.id]
    end
  end

  # A person this server knows, named `name`.
  defp named!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|sharing-#{n}",
        provider: "github",
        email: "sharing#{n}@example.com",
        verified: true,
        name: name
      })

    user
  end

  # Runs `change` once, in this process, right after the first statement
  # this process issues from now on, and sends its result back as
  # `{:changed, result}`. The event fires once the statement has answered
  # and returned its connection, so whatever `change` commits lands after
  # that statement and before anything issued next.
  defp after_first_query!(change) do
    test = self()
    handler = "after-first-query-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, _meta, _config ->
        if self() == test and is_nil(Process.get(handler)) do
          Process.put(handler, :changed)
          send(test, {:changed, change.()})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Runs `fun` and answers its result with the number of statements this
  # process issued while it ran.
  defp counting_queries(fun) do
    test = self()
    ref = make_ref()
    handler = "counting-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, _meta, _config ->
        if self() == test, do: send(test, {ref, :queried})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, queried(ref, 0)}
  end

  defp queried(ref, count) do
    receive do
      {^ref, :queried} -> queried(ref, count + 1)
    after
      0 -> count
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
    do: %{Prima.Actor.in_athanor(athanor_id) | user_id: user_id}

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
      Cyfr.Test.Settings.put("max_members_per_group", 2)

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

      Cyfr.Bus.subscribe_global(Cyfr.Bus.memberships(user.id))
      assert {:ok, 2} = Members.activate_invited(user)

      assert Members.member?(user.id, athanor.id)
      assert Members.member?(user.id, other.id)
      assert_receive %Cyfr.Bus.Membership{change: :joined}

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

    test "retires in one transition the person's sessions bound to it and their clients and certificates there",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      leaver = person(n)
      stayer = person(n + 1)
      other = group!(n)
      {:ok, :added} = Members.add(athanor, [user_id: leaver.id], "system")
      {:ok, :added} = Members.add(athanor, [user_id: stayer.id], "system")
      {:ok, :added} = Members.add(other, [user_id: leaver.id], "system")

      bound = session!(leaver.id, athanor.id)
      elsewhere = session!(leaver.id, other.id)
      client = paired!(athanor.id, leaver.id)
      cert = certificate!(athanor.id, leaver.id, client)
      kept_client = paired!(other.id, leaver.id)
      kept_cert = certificate!(other.id, leaver.id, kept_client)
      stayer_session = session!(stayer.id, athanor.id)
      leaver_id = leaver.id
      Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

      assert :ok = Members.remove_member(athanor, user_id: leaver.id)

      refute Members.member?(leaver.id, athanor.id)
      refute session?(bound)
      assert standing(PairedClient, client) == "revoked"
      assert state(DeviceCertificate, cert) == "revoked"
      assert_receive %Cyfr.Bus.Session{kind: :revoked, user_id: ^leaver_id}

      # The other athanor's seat, session, client and certificate stand, as
      # do the identity and everyone else's.
      assert Members.member?(leaver.id, other.id)
      assert session?(elsewhere)
      assert standing(PairedClient, kept_client) == "active"
      assert state(DeviceCertificate, kept_cert) == "active"
      assert session?(stayer_session)
      assert {:ok, %{provenance: "local"}} = Arca.PersonIdentities.get(server(), leaver.id)
      assert {:ok, %{status: "active"}} = Athanors.get(athanor.id)
    end

    test "a removal that fails to retire one certificate rolls back whole, and its retry goes through",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      leaver = person(n)
      stayer = person(n + 1)
      {:ok, :added} = Members.add(athanor, [user_id: leaver.id], "system")
      {:ok, :added} = Members.add(athanor, [user_id: stayer.id], "system")
      bound = session!(leaver.id, athanor.id)
      client = paired!(athanor.id, leaver.id)
      cert = certificate!(athanor.id, leaver.id, client)
      failure = fail_on!("device_certificates", "UPDATE")

      assert {:error, :database_error} = Members.remove_member(athanor, user_id: leaver.id)

      assert Members.member?(leaver.id, athanor.id)
      assert session?(bound)
      assert standing(PairedClient, client) == "active"
      assert state(DeviceCertificate, cert) == "active"

      clear_failure!(failure)

      assert :ok = Members.remove_member(athanor, user_id: leaver.id)
      refute Members.member?(leaver.id, athanor.id)
      refute session?(bound)
      assert state(DeviceCertificate, cert) == "revoked"
    end

    test "a person who holds no seat there is not found, and a person's own athanor keeps its owner",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      stranger = person(n)
      assert {:error, :not_found} = Members.remove_member(athanor, user_id: stranger.id)

      {:ok, own} =
        Athanors.create(%{
          kind: "person",
          name: "Own #{n}",
          slug: "own-#{n}",
          owner_user_id: stranger.id,
          created_by: stranger.id
        })

      {:ok, _} = Members.ensure(stranger.id, scope: "athanor", athanor_id: own.id)
      assert {:error, :person_athanor} = Members.remove_member(own, user_id: stranger.id)

      # A caller's copy that misnames the kind is decided again on the
      # locked row, and the owner stays.
      assert {:error, :person_athanor} =
               Members.remove_member(%{own | kind: "group"}, user_id: stranger.id)

      assert Members.member?(stranger.id, own.id)
    end
  end

  describe "membership by identifier" do
    test "an identifier a person here holds seats them; an unknown one is invited and waits at the door",
         %{athanor: athanor} do
      known = identifier()
      user = remote!(known)

      assert {:ok, :added} = Members.add(athanor, [identifier: known], "system")
      assert Members.member?(user.id, athanor.id)

      # Unknown here: invited, and queued for the operator by the door; the
      # directory it names is not asked, since only the person's own
      # sign-in carries their genesis.
      unknown = identifier()
      assert {:ok, :invited} = Members.add(athanor, [identifier: unknown], "system")
      assert {:ok, :invited} = Members.add(athanor, [identifier: unknown], "system")

      assert [%{status: "invited", user_id: nil, email: nil}] =
               Enum.filter(
                 rows!(Members.list_by_athanor(athanor.id)),
                 &(&1.person_identifier == unknown)
               )

      assert [%{kind: "identifier", status: "requested"}] =
               Enum.filter(Sanctum.Door.Store.requests(), &(&1.value == unknown))

      # An identifier the door already admits queues nothing.
      admitted = identifier()
      {:ok, _} = Sanctum.Door.Store.allow("identifier", admitted, "ops")
      assert Sanctum.Door.identifier_admitted?(admitted)
      assert {:ok, :invited} = Members.add(athanor, [identifier: admitted], "system")
      refute Enum.any?(Sanctum.Door.Store.requests(), &(&1.value == admitted))

      # `*` admits every identifier but a denied one: the deny outranks it.
      {:ok, _} = Sanctum.Door.Store.deny("identifier", admitted, "ops")
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
      refute Sanctum.Door.identifier_admitted?(admitted)
      assert Sanctum.Door.identifier_admitted?(identifier())

      assert {:error, :invalid_identifier} =
               Members.add(athanor, [identifier: "per_not-an-identifier"], "system")
    end

    test "only a cyfr identity claims an identifier invitation: another door's subject spelled as one claims nothing",
         %{athanor: athanor} do
      identifier = identifier()
      {:ok, :invited} = Members.add(athanor, [identifier: identifier], "system")

      # The subject another door asserts is that door's to choose; spelled
      # as an identifier, it proves no identifier.
      for {provider, issuer} <- [
            {"github", "https://github.com"},
            {"oidcc", "https://idp.example"}
          ] do
        {:ok, user} =
          Sanctum.Tenancy.Users.upsert_from_provider(%{
            id: "#{provider}|#{issuer}|#{identifier}",
            provider: provider,
            verified: :unknown
          })

        assert {:ok, 0} = Members.activate_invited(user), provider
        refute Members.member?(user.id, athanor.id), provider
      end

      assert [%{status: "invited", user_id: nil}] =
               Enum.filter(
                 rows!(Members.list_by_athanor(athanor.id)),
                 &(&1.person_identifier == identifier)
               )
    end

    test "the first cyfr sign-in claims every invitation its identifier holds, as an email invite is claimed",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      id = identifier()
      other = group!(n)
      {:ok, :invited} = Members.add(athanor, [identifier: id], "system")
      {:ok, :invited} = Members.add(other, [identifier: id], "system")

      # Someone whose cyfr identity names another identifier claims none.
      stranger = remote!(identifier())
      assert {:ok, 0} = Members.activate_invited(stranger)

      user = remote!(id)
      Cyfr.Bus.subscribe_global(Cyfr.Bus.memberships(user.id))
      assert {:ok, 2} = Members.activate_invited(user)

      assert Members.member?(user.id, athanor.id)
      assert Members.member?(user.id, other.id)
      assert_receive %Cyfr.Bus.Membership{change: :joined}
      refute Enum.any?(rows!(Members.list_by_athanor(athanor.id)), &(&1.status == "invited"))

      assert {:ok, 0} = Members.activate_invited(user)
    end

    test "remove_member/2 by identifier withdraws its invitation, or removes the person who holds it",
         %{athanor: athanor} do
      pending = identifier()
      {:ok, :invited} = Members.add(athanor, [identifier: pending], "system")
      assert :ok = Members.remove_member(athanor, identifier: pending)

      refute Enum.any?(
               rows!(Members.list_by_athanor(athanor.id)),
               &(&1.person_identifier == pending)
             )

      assert {:error, :not_found} = Members.remove_member(athanor, identifier: pending)

      held = identifier()
      user = remote!(held)
      {:ok, :added} = Members.add(athanor, [user_id: user.id], "system")

      {:ok, :added} =
        Members.add(athanor, [user_id: person(System.unique_integer([:positive])).id], "system")

      assert :ok = Members.remove_member(athanor, identifier: held)
      refute Members.member?(user.id, athanor.id)
    end

    test "withdraw_invites_for_identifier/1 drops every invitation the identifier holds",
         %{athanor: athanor} do
      n = System.unique_integer([:positive])
      id = identifier()
      other = group!(n)
      {:ok, :invited} = Members.add(athanor, [identifier: id], "system")
      {:ok, :invited} = Members.add(other, [identifier: id], "system")

      assert Members.withdraw_invites_for_identifier(id) == 2
      assert Members.withdraw_invites_for_identifier(id) == 0
      assert Members.withdraw_invites_for_identifier(nil) == 0

      user = remote!(id)
      assert {:ok, 0} = Members.activate_invited(user)
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

      refute Subs.follows?(Prima.Actor.in_athanor(athanor.id), thread, leaver.id)
      assert Subs.follows?(Prima.Actor.in_athanor(athanor.id), thread, stayer.id)
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

  defp server, do: Prima.Actor.system()

  defp group!(n) do
    {:ok, group} =
      Athanors.create(%{
        kind: "group",
        name: "Other #{n}",
        slug: "other-#{n}-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    group
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("mem-#{System.unique_integer()}")

  # A person the `cyfr` door admitted: their identity names `identifier`
  # and its directory, and holds no key.
  defp remote!(identifier) do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr",
          verified: :unknown
        },
        remote: %{identifier: identifier, directory_url: "https://dir.example"}
      )

    user
  end

  # A session of the person, bound to the athanor; answers its row key.
  defp session!(user_id, athanor_id) do
    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: user_id,
          athanor_id: athanor_id,
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    Sanctum.Session.token_hash(session.token)
  end

  defp session?(hash), do: match?({:ok, _}, Arca.SessionStorage.get_session(hash))

  # A person whose provider proved `email`: the address claims what is held for it.
  defp verified!(subject, email) do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|#{subject}",
        provider: "github",
        email: email,
        verified: true
      })

    user
  end

  # Runs `claim` once, in this process, right after the first statement
  # that reads an invitation from the memberships table, and sends its
  # result back as `{:claimed, result}`: the claim commits between a
  # withdrawal's lookup and its delete. The event fires in the querying
  # process after the statement has returned its connection, so the claim
  # runs its own statements as an invitee's sign-in would.
  defp claim_after_lookup!(claim) do
    test = self()
    handler = "claim-after-lookup-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == test and is_nil(Process.get(handler)) and meta[:source] == "memberships" and
             String.starts_with?(meta[:query], "SELECT") and meta[:query] =~ "'invited'" do
          Process.put(handler, :claimed)
          send(test, {:claimed, claim.()})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A paired client and its certificate, inserted as their stores write
  # them: recording them is fenced by the member's slot and proved by a
  # device key, which is not what these cases are about.
  defp paired!(athanor_id, user_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("pcl")

    {1, _} =
      Arca.Repo.insert_all(PairedClient, [
        %{
          id: id,
          athanor_id: athanor_id,
          user_id: user_id,
          source_kind: "session",
          source_id: "src_#{System.unique_integer([:positive])}",
          standing: "active",
          label: "a browser",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  defp certificate!(athanor_id, user_id, paired_client_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("dct")
    n = System.unique_integer([:positive])

    {1, _} =
      Arca.Repo.insert_all(DeviceCertificate, [
        %{
          id: id,
          athanor_id: athanor_id,
          paired_client_id: paired_client_id,
          user_id: user_id,
          subject_kind: "local",
          device_public_key: :crypto.strong_rand_bytes(32),
          issuing_home: "https://home.example",
          audience_home: "https://home.example",
          not_before: now,
          expires_at: DateTime.add(now, 3600, :second),
          certificate: "cert-#{n}",
          digest: Prima.Digest.sha256("cert-#{n}"),
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  defp standing(schema, id), do: Arca.Repo.get(schema, id).standing
  defp state(schema, id), do: Arca.Repo.get(schema, id).state

  # A trigger that makes one statement fail inside the transition, spelled
  # per adapter; the sandbox rolls it back with the test, and
  # `clear_failure!/1` drops it within one.
  defp fail_on!(table, event) do
    name = "mem_fail_#{table}_#{String.downcase(event)}"

    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!(
          "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} " <>
            "BEGIN SELECT RAISE(ABORT, 'injected #{event} failure'); END"
        )

      _postgres ->
        Arca.Repo.query!(
          "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
            "$$ BEGIN RAISE EXCEPTION 'injected #{event} failure'; END $$"
        )

        Arca.Repo.query!(
          "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} " <>
            "FOR EACH ROW EXECUTE FUNCTION #{name}()"
        )
    end

    {name, table}
  end

  defp clear_failure!({name, table}) do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("DROP TRIGGER #{name}")

      _postgres ->
        Arca.Repo.query!("DROP TRIGGER #{name} ON #{table}")
        Arca.Repo.query!("DROP FUNCTION #{name}()")
    end
  end
end
