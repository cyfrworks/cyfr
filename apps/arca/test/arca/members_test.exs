# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MembersTest do
  @moduledoc """
  The membership rows, and the two shapes the facade has: the roster of
  one athanor, whose id comes from the actor and can name no other, and
  the fabric — a platform grant that names no athanor, a person's seats
  across every athanor, an invitation keyed on an address — which is
  asked for with the platform scope.
  """
  use ExUnit.Case, async: true

  alias Arca.{Athanors, Members}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Cyfr.Actor.system()

  defp in_athanor(id), do: %{Cyfr.Actor.system() | athanor_id: id, scope: :athanor}

  defp group! do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Athanors.insert(server(), %{
        kind: "group",
        name: "G#{n}",
        slug: "mem-g-#{n}",
        created_by: "system"
      })

    athanor
  end

  defp person_id, do: "usr_#{System.unique_integer([:positive])}"

  defp watch_queries! do
    handler = "members-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, _meta, _config -> if self() == parent, do: send(parent, :queried) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Every query this process has run so far, forgotten: what the refusals
  # below must not produce is a query of their own.
  defp drain_queries! do
    receive do
      :queried -> drain_queries!()
    after
      0 -> :ok
    end
  end

  # Called through `apply/3`: the refusal under test is the one a caller
  # makes at run time, and a literal call the compiler can type-check
  # would be refused before this file ever runs.
  defp refused!(fun, args) do
    assert_raise FunctionClauseError, fn -> apply(Members, fun, args) end
  end

  describe "the actor is the first argument, and a wrong one refuses before any query" do
    test "an actor with no athanor is refused by every inside-the-tenant function" do
      watch_queries!()
      nobody = %Cyfr.Actor{athanor_id: nil, user_id: "someone"}

      assert {:error, :no_athanor} = Members.seat(nobody, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(nobody, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited(nobody, "a@example.com")
      assert {:error, :no_athanor} = Members.list(nobody)
      assert {:error, :no_athanor} = Members.count_active(nobody)
      assert {:error, :no_athanor} = Members.count_seats(nobody)
      assert {:error, :no_athanor} = Members.active_user_ids(nobody)
      refute_received :queried

      # The probe is live: an actor with an athanor does query.
      assert {:ok, 0} = Members.count_active(in_athanor("ath_nobody"))
      assert_received :queried
    end

    test "an actor whose athanor is the empty string is refused, not answered emptily" do
      watch_queries!()
      # `""` is an identity that was never resolved, the same thing the
      # layer that establishes identity refuses outright. Taking it would
      # filter on `athanor_id == ""`, match nothing, and answer an empty
      # roster where the refusal belongs.
      unresolved = %{Cyfr.Actor.system() | athanor_id: "", scope: :athanor}

      assert {:error, :no_athanor} = Members.seat(unresolved, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(unresolved, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited(unresolved, "a@example.com")
      assert {:error, :no_athanor} = Members.list(unresolved)
      assert {:error, :no_athanor} = Members.count_active(unresolved)
      assert {:error, :no_athanor} = Members.count_seats(unresolved)
      assert {:error, :no_athanor} = Members.active_user_ids(unresolved)
      refute_received :queried
    end

    test "an athanor-scoped actor is refused by every across-tenants function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")
      row = %Arca.Schemas.Membership{id: "mem_x"}

      assert {:error, :cross_tenant} = Members.grant_platform(member, %{user_id: "usr_1"})
      assert {:error, :cross_tenant} = Members.get(member, "mem_x")
      assert {:error, :cross_tenant} = Members.find_platform(member, "usr_1")
      assert {:error, :cross_tenant} = Members.delete(member, row)
      assert {:error, :cross_tenant} = Members.list_platform(member)
      assert {:error, :cross_tenant} = Members.list_active_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.list_all_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.delete_all_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.shared_estate?(member, "usr_1", "usr_2")

      assert {:error, :cross_tenant} =
               Members.activate_invited(member, "usr_1", "a@example.com", DateTime.utc_now())

      assert {:error, :cross_tenant} =
               Members.withdraw_invites_for_email(member, "a@example.com")

      assert {:error, :cross_tenant} = Members.ensure_platform(member, "usr_1", [])
      assert {:error, :cross_tenant} = Members.revoke_platform(member, "usr_1")

      assert {:error, :cross_tenant} =
               Members.reconcile_platform(member, %Arca.Schemas.JobClaim{}, [])

      refute_received :queried
    end

    test "a plain map, or a bare athanor id, raises before any query" do
      watch_queries!()
      athanor = group!()
      drain_queries!()

      # A map carrying an actor's fields is not an actor either.
      map = %{athanor_id: athanor.id, scope: :athanor}
      refused!(:seat, [map, %{user_id: "usr_1"}])
      refused!(:list, [map, []])
      refused!(:count_active, [map])
      refused!(:seat, [athanor.id, %{user_id: "usr_1"}])
      refused!(:list, [athanor.id, []])
      refused!(:count_active, [athanor.id])
      refute_received :queried
    end
  end

  describe "inside one tenant" do
    test "a seat lands in the actor's athanor, whatever athanor the attrs name" do
      a = group!()
      b = group!()
      user = person_id()

      assert {:ok, row} =
               Members.seat(in_athanor(a.id), %{
                 user_id: user,
                 scope: "athanor",
                 athanor_id: b.id,
                 added_by: "system"
               })

      assert row.athanor_id == a.id
      assert {:ok, [^user]} = Members.active_user_ids(in_athanor(a.id))
      assert {:ok, []} = Members.active_user_ids(in_athanor(b.id))
    end

    test "a read for one actor cannot return another athanor's rows" do
      a = group!()
      b = group!()
      here = person_id()
      there = person_id()

      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: here, added_by: "system"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: there, added_by: "system"})

      assert {:ok, [%{user_id: ^here}]} = Members.list(in_athanor(a.id))
      assert {:ok, [%{user_id: ^there}]} = Members.list(in_athanor(b.id))
      assert {:ok, 1} = Members.count_active(in_athanor(a.id))
      assert {:ok, %{user_id: ^here}} = Members.find(in_athanor(a.id), here)
      assert {:error, :not_found} = Members.find(in_athanor(a.id), there)
    end

    test "an athanor with no row is :unknown_athanor, and a duplicate is :conflict" do
      athanor = group!()
      user = person_id()

      assert {:error, :unknown_athanor} =
               Members.seat(in_athanor("ath_missing"), %{user_id: user, added_by: "system"})

      assert {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})

      assert {:error, :conflict} =
               Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})
    end

    test "a validation refusal names its fields and carries no changeset" do
      athanor = group!()

      assert {:error, {:invalid, %{scope: [_ | _]}}} =
               Members.seat(in_athanor(athanor.id), %{user_id: person_id(), scope: "superadmin"})
    end

    test "seats count invitations; active members do not" do
      athanor = group!()
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: person_id(), added_by: "x"})

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{
          email: "invitee@example.com",
          status: "invited",
          added_by: "x"
        })

      assert {:ok, 2} = Members.count_seats(in_athanor(athanor.id))
      assert {:ok, 1} = Members.count_active(in_athanor(athanor.id))

      assert {:ok, %{status: "invited"}} =
               Members.find_invited(in_athanor(athanor.id), "invitee@example.com")
    end
  end

  describe "across tenants" do
    test "a platform grant names no athanor and is read back as the person's" do
      user = person_id()
      assert {:ok, row} = Members.grant_platform(server(), %{user_id: user, added_by: "system"})
      assert row.athanor_id == nil
      assert row.scope == "platform"

      assert {:ok, %{id: id}} = Members.find_platform(server(), user)
      assert id == row.id
      assert {:ok, %{id: ^id}} = Members.get(server(), row.id)
      assert Enum.any?(elem(Members.list_platform(server()), 1), &(&1.id == row.id))

      assert {:ok, %{removed: 1, session_hashes: []}} = Members.revoke_platform(server(), user)
      assert {:error, :not_found} = Members.find_platform(server(), user)
    end

    test "a person's rows are read and swept across every athanor they sat in" do
      a = group!()
      b = group!()
      user = person_id()
      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: user, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: user, added_by: "x"})
      {:ok, _} = Members.grant_platform(server(), %{user_id: user, added_by: "x"})

      assert {:ok, rows} = Members.list_active_for_user(server(), user)
      assert length(rows) == 3
      assert {:ok, all} = Members.list_all_for_user(server(), user)
      assert length(all) == 3

      assert {:ok, true} = shared?(a.id, user)
      assert {:ok, 3} = Members.delete_all_for_user(server(), user)
      assert {:ok, []} = Members.list_all_for_user(server(), user)
    end

    test "two people share an estate only while both seats are active and the estate is" do
      athanor = group!()
      alice = person_id()
      bob = person_id()
      carol = person_id()
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: alice, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: bob, added_by: "x"})

      assert {:ok, true} = Members.shared_estate?(server(), alice, bob)
      assert {:ok, false} = Members.shared_estate?(server(), alice, carol)

      {:ok, _} = Athanors.update(in_athanor(athanor.id), %{status: "archived"})
      assert {:ok, false} = Members.shared_estate?(server(), alice, bob)
    end
  end

  describe "activate_invited/4" do
    test "claims every invitation the address holds, once" do
      a = group!()
      b = group!()
      user = person_id()
      email = "claim-#{System.unique_integer([:positive])}@example.com"

      for athanor <- [a, b] do
        {:ok, _} =
          Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})
      end

      assert {:ok, claimed} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert Enum.sort(claimed) == Enum.sort([a.id, b.id])
      assert {:ok, [^user]} = Members.active_user_ids(in_athanor(a.id))

      # The seat carries no address once it names a person.
      assert {:ok, [%{status: "active", email: nil}]} = Members.list(in_athanor(a.id))

      # A second activation finds nothing, so there is no second membership.
      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, 1} = Members.count_active(in_athanor(a.id))
    end

    test "an invitation for an athanor the person already sits in is dropped, not duplicated" do
      athanor = group!()
      user = person_id()
      email = "dup-#{System.unique_integer([:positive])}@example.com"

      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})

      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, [%{status: "active", user_id: ^user}]} = Members.list(in_athanor(athanor.id))
    end

    test "an invitation already withdrawn claims nothing" do
      athanor = group!()
      user = person_id()
      email = "gone-#{System.unique_integer([:positive])}@example.com"

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})

      assert {:ok, [withdrawn]} = Members.withdraw_invites_for_email(server(), email)
      assert withdrawn == athanor.id
      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, 0} = Members.count_seats(in_athanor(athanor.id))
    end
  end

  describe "the platform transitions" do
    test "a grant is written once and then held", %{} do
      user = person!()
      facts = facts(user)

      assert {:ok, %{membership: row, granted: true}} =
               Members.ensure_platform(server(), user.id, expected_identity: facts)

      assert row.scope == "platform" and row.athanor_id == nil

      assert {:ok, %{membership: %{id: same}, granted: false}} =
               Members.ensure_platform(server(), user.id, expected_identity: facts)

      assert same == row.id
      # Without a sign-in's facts the grant is the server's own act.
      assert {:ok, %{granted: false}} = Members.ensure_platform(server(), user.id, [])
    end

    test "a grant answers to the facts the sign-in asserted, in either direction of change" do
      # The operator's assertion was overtaken: the row now carries another
      # address, so the earlier sign-in grants nothing.
      ops = person!(%{email: "ops-#{uniq()}@example.com"})
      asserted = facts(ops)
      moved!(ops, email: "someone-#{uniq()}@example.com")

      assert {:error, :stale_identity} =
               Members.ensure_platform(server(), ops.id, expected_identity: asserted)

      assert {:error, :not_found} = Members.find_platform(server(), ops.id)

      # And the other way: a non-operator's earlier assertion does not
      # revoke the grant a later operator assertion now stands behind.
      later = person!(%{email: "plain-#{uniq()}@example.com"})
      stale = facts(later)
      moved!(later, email: "ops-#{uniq()}@example.com")
      {:ok, _} = Members.ensure_platform(server(), later.id, expected_identity: facts(reload(later)))
      token = session!(later.id)

      assert {:error, :stale_identity} =
               Members.revoke_platform(server(), later.id, expected_identity: stale)

      assert {:ok, _} = Members.find_platform(server(), later.id)
      assert {:ok, _} = Arca.SessionStorage.get_session(token)
    end

    test "a verification claim that changed is stale, and an explicitly unverified email is never granted" do
      user = person!(%{email_verified: true})
      asserted = facts(user)
      moved!(user, email_verified: nil)

      assert {:error, :stale_identity} =
               Members.ensure_platform(server(), user.id, expected_identity: asserted)

      unverified = person!(%{email_verified: false})

      assert {:error, :stale_identity} =
               Members.ensure_platform(server(), unverified.id,
                 expected_identity: facts(unverified)
               )

      assert {:error, :not_found} = Members.find_platform(server(), unverified.id)

      # A revoke needs no proved address: it only takes away.
      {:ok, _} = Members.ensure_platform(server(), unverified.id, [])

      assert {:ok, %{removed: 1}} =
               Members.revoke_platform(server(), unverified.id,
                 expected_identity: facts(unverified)
               )
    end

    test "an unchanged delayed verdict still lands" do
      user = person!()
      asserted = facts(user)
      # Time passes and the row is touched, but its identity facts do not change.
      moved!(user, display_name: "Renamed", last_seen_at: DateTime.utc_now())

      assert {:ok, %{granted: true}} =
               Members.ensure_platform(server(), user.id, expected_identity: asserted)
    end

    test "a revoke removes the grant and exactly that person's sessions, and answers their hashes" do
      user = person!()
      other = person!()
      {:ok, _} = Members.ensure_platform(server(), user.id, [])
      mine = [session!(user.id), session!(user.id)]
      theirs = session!(other.id)

      assert {:ok, %{removed: 1, session_hashes: hashes}} =
               Members.revoke_platform(server(), user.id)

      assert Enum.sort(hashes) == Enum.sort(mine)
      for hash <- mine, do: assert({:error, _} = Arca.SessionStorage.get_session(hash))
      assert {:ok, _} = Arca.SessionStorage.get_session(theirs)
      assert {:error, :not_found} = Members.find_platform(server(), user.id)
    end

    test "an absent grant leaves ordinary sessions alone" do
      user = person!()
      token = session!(user.id)

      assert {:ok, %{removed: 0, session_hashes: []}} = Members.revoke_platform(server(), user.id)
      assert {:ok, _} = Arca.SessionStorage.get_session(token)
    end
  end

  describe "reconcile_platform/3" do
    test "removes every grant the list no longer names with its sessions, and records success" do
      kept = person!()
      dropped = person!()
      {:ok, _} = Members.ensure_platform(server(), kept.id, [])
      {:ok, _} = Members.ensure_platform(server(), dropped.id, [])
      dropped_sessions = [session!(dropped.id)]
      kept_session = session!(kept.id)
      claim = claim!()

      assert {:ok, %{claim: renewed, revoked: revoked}} =
               reconcile(claim, operators: [kept.email])

      assert revoked == [%{user_id: dropped.id, session_hashes: dropped_sessions}]
      assert {:ok, _} = Members.find_platform(server(), kept.id)
      assert {:error, :not_found} = Members.find_platform(server(), dropped.id)
      assert {:ok, _} = Arca.SessionStorage.get_session(kept_session)
      assert {:error, _} = Arca.SessionStorage.get_session(hd(dropped_sessions))

      # The final checked renewal is the claim the caller releases, and its
      # evidence says who completed it under which list.
      assert renewed.fence == claim.fence + 1

      assert %{
               "version" => 1,
               "status" => "complete",
               "policy_digest" => "digest-1",
               "owner" => "boot_reconcile"
             } = Jason.decode!(renewed.detail)

      assert :ok = Arca.JobClaims.release(renewed)
    end

    test "a grant naming a person with no row refuses the whole reconcile" do
      dropped = person!()
      {:ok, _} = Members.ensure_platform(server(), dropped.id, [])
      {:ok, _} = Members.grant_platform(server(), %{user_id: person_id(), added_by: "x"})
      claim = claim!()

      assert {:error, :missing_user} = reconcile(claim, operators: [])

      # Nothing moved: the delisted grant and the claim are as they were.
      assert {:ok, _} = Members.find_platform(server(), dropped.id)
      assert {:ok, %{fence: fence}} = Arca.JobClaims.read("bootstrap", claim.key)
      assert fence == claim.fence
    end

    test "a claim taken or lapsed, or a slot lost, commits nothing" do
      dropped = person!()
      {:ok, _} = Members.ensure_platform(server(), dropped.id, [])

      taken = claim!()
      {:ok, _moved} = Arca.JobClaims.record(taken, "a peer's write")
      assert {:error, :claim_taken} = reconcile(taken, operators: [])

      {:ok, lapsed} = Arca.JobClaims.claim("bootstrap", "cell-#{uniq()}", "boot_reconcile", 1)
      Process.sleep(5)
      assert {:error, :claim_lapsed} = reconcile(lapsed, operators: [])

      slot = slot!()
      assert {:error, :slot_lost} = reconcile(claim!(), operators: [], slot: %{slot | owner: "x"})

      expired = slot!(-1_000)
      assert {:error, :slot_lost} = reconcile(claim!(), operators: [], slot: expired)

      assert {:ok, _} = Members.find_platform(server(), dropped.id)

      # Under the slot this member does hold, the same reconcile lands.
      assert {:ok, %{revoked: [%{user_id: user_id}]}} =
               reconcile(claim!(), operators: [], slot: slot)

      assert user_id == dropped.id
    end
  end

  defp uniq, do: System.unique_integer([:positive])

  defp person!(overrides \\ %{}) do
    n = uniq()
    now = DateTime.utc_now()

    user_attrs =
      Map.merge(
        %{
          id: Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix()),
          provider: "github",
          email: "m#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        overrides
      )

    {:ok, user} =
      Arca.Users.mint(server(), user_attrs, %{
        key: "github|https://github.com|m#{n}",
        provider: "github",
        issuer: "https://github.com",
        subject: "m#{n}",
        first_seen_at: now,
        last_seen_at: now
      })

    user
  end

  defp reload(user), do: elem(Arca.Users.get(server(), user.id), 1)

  defp facts(user), do: %{email: user.email, email_verified: user.email_verified}

  defp moved!(user, changes) do
    {:ok, _} = Arca.Users.update(server(), reload(user), Map.new(changes))
    :ok
  end

  defp session!(user_id) do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      Arca.SessionStorage.create_session(hash, %{
        user_id: user_id,
        provider: "github",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    hash
  end

  defp claim!(lease_ms \\ 60_000) do
    {:ok, claim} =
      Arca.JobClaims.claim("bootstrap", "cell-#{uniq()}", "boot_reconcile", lease_ms)

    claim
  end

  # A slot row written for this test alone: the verify reads the row, never
  # the process-wide cache a take would also write.
  defp slot!(lease_offset_ms \\ 60_000) do
    now = Arca.ServerMetaStorage.now!()
    node = "node-members-#{uniq()}"

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.CellLease, [
        %{
          node: node,
          owner: "boot_reconcile",
          generation: 1,
          fence: 1,
          lease_until: DateTime.add(now, lease_offset_ms, :millisecond),
          taken_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

    %{
      node: node,
      owner: "boot_reconcile",
      generation: 1,
      fence: 1,
      lease_until: DateTime.add(now, lease_offset_ms, :millisecond)
    }
  end

  defp reconcile(claim, opts) do
    Members.reconcile_platform(
      server(),
      claim,
      Keyword.merge([slot: :none, policy_digest: "digest-1", lease_ms: 60_000], opts)
    )
  end

  defp shared?(athanor_id, user_id) do
    with {:ok, ids} <- Members.active_user_ids(in_athanor(athanor_id)) do
      {:ok, user_id in ids}
    end
  end
end

defmodule Arca.MembersLockTest do
  @moduledoc """
  The platform transitions under two real connections, outside the
  sandbox: two concurrent grants of one person write one row, and a
  grant waiting behind a change to the person's row acts on what that
  change committed — on PostgreSQL by waiting on the row, on SQLite by
  waiting at its own BEGIN.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Members
  alias Arca.Schemas.{ExternalIdentity, Membership, User}
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Cyfr.Actor.system()

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    id = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())

    {:ok, user} =
      unboxed(fn ->
        Arca.Users.mint(
          server(),
          %{
            id: id,
            provider: "github",
            email: "lock#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|lock#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "lock#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, user_id: ^id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^id))
        Arca.Repo.delete_all(where(User, id: ^id))
      end)
    end)

    {:ok, user: user, facts: %{email: user.email, email_verified: true}}
  end

  # Two racers: on SQLite a waiter sleeps out its busy timeout inside the
  # driver on a dirty I/O scheduler, and the partitioned runs give each VM
  # two of them, so more waiters than that starve the lock's own holder.
  test "concurrent idempotent grants write one row, and exactly one says it wrote it", %{
    user: user,
    facts: facts
  } do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          unboxed(fn -> Members.ensure_platform(server(), user.id, expected_identity: facts) end)
        end)
      end)
      |> Enum.map(&Task.await(&1, 25_000))

    assert Enum.all?(results, &match?({:ok, %{granted: _}}, &1))
    assert Enum.count(results, &match?({:ok, %{granted: true}}, &1)) == 1

    assert 1 ==
             unboxed(fn ->
               Arca.Repo.aggregate(
                 where(Membership, user_id: ^user.id, scope: "platform"),
                 :count
               )
             end)
  end

  test "a grant waiting behind a change to the person acts on the change, not on its read", %{
    user: user,
    facts: facts
  } do
    test = self()

    changer =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(u in User, where: u.id == ^user.id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()

            send(test, :holding)

            receive do
              :commit -> :ok
            end

            Arca.Repo.update_all(where(User, id: ^user.id), set: [email: "moved@example.com"])
          end)
        end)
      end)

    assert_receive :holding, 5_000

    granter =
      Task.async(fn ->
        unboxed(fn -> Members.ensure_platform(server(), user.id, expected_identity: facts) end)
      end)

    refute Task.yield(granter, 300), "the grant decided while the person's row was held"
    send(changer.pid, :commit)
    assert {:ok, {1, _}} = Task.await(changer, 25_000)
    assert {:error, :stale_identity} = Task.await(granter, 25_000)

    assert {:error, :not_found} = unboxed(fn -> Members.find_platform(server(), user.id) end)
  end
end
