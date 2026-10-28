# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MembersTest do
  @moduledoc """
  The membership rows, and the two shapes the facade has: the roster of
  one athanor, whose id comes from the actor and can name no other, and
  the fabric — a platform grant that names no athanor, a person's seats
  across every athanor, an invitation keyed on an identifier — which is
  asked for with the platform scope.
  """
  use ExUnit.Case, async: true

  alias Arca.{Athanors, Members}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

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
      nobody = %Prima.Actor{athanor_id: nil, user_id: "someone"}

      assert {:error, :no_athanor} = Members.seat(nobody, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(nobody, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited_identifier(nobody, "per_x")
      assert {:error, :no_athanor} = Members.withdraw_invitation(nobody, "mem_x")
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
      unresolved = %{Prima.Actor.system() | athanor_id: "", scope: :athanor}

      assert {:error, :no_athanor} = Members.seat(unresolved, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(unresolved, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited_identifier(unresolved, "per_x")
      assert {:error, :no_athanor} = Members.withdraw_invitation(unresolved, "mem_x")
      assert {:error, :no_athanor} = Members.list(unresolved)
      assert {:error, :no_athanor} = Members.count_active(unresolved)
      assert {:error, :no_athanor} = Members.count_seats(unresolved)
      assert {:error, :no_athanor} = Members.active_user_ids(unresolved)
      refute_received :queried
    end

    test "an athanor-scoped actor is refused by every across-tenants function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")

      assert {:error, :cross_tenant} = Members.get(member, "mem_x")
      assert {:error, :cross_tenant} = Members.find_platform(member, "usr_1")
      assert {:error, :cross_tenant} = Members.list_platform(member)
      assert {:error, :cross_tenant} = Members.list_active_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.shared_athanor?(member, "usr_1", "usr_2")
      assert {:error, :cross_tenant} = Members.people_sharing(member, "usr_1")

      assert {:error, :cross_tenant} =
               Members.activate_invited_identifier(member, "usr_1", "per_x", DateTime.utc_now())

      assert {:error, :cross_tenant} = Members.withdraw_invites_for_identifier(member, "per_x")

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

      invitee = identifier()

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{
          person_identifier: invitee,
          status: "invited",
          added_by: "x"
        })

      assert {:ok, 2} = Members.count_seats(in_athanor(athanor.id))
      assert {:ok, 1} = Members.count_active(in_athanor(athanor.id))

      assert {:ok, %{status: "invited"}} =
               Members.find_invited_identifier(in_athanor(athanor.id), invitee)
    end

    test "a reserve: closure counts the seats before the row is written, and its refusal writes nothing" do
      athanor = group!()
      actor = in_athanor(athanor.id)

      {:ok, _} =
        Members.seat(actor, %{person_identifier: identifier(), status: "invited", added_by: "x"})

      test = self()
      refused = person_id()

      full = fn ->
        send(test, {:counted, Members.count_seats(actor)})
        {:error, {:full, 1}}
      end

      assert {:error, {:full, 1}} =
               Members.seat(actor, %{user_id: refused, added_by: "x"}, reserve: full)

      assert_received {:counted, {:ok, 1}}
      assert {:error, :not_found} = Members.find(actor, refused)
      assert {:ok, 1} = Members.count_seats(actor)

      # The same refusal through an invitation's write, and an admitting
      # closure seats as `seat/2` does.
      full_invitee = identifier()

      assert {:error, {:full, 1}} =
               Members.seat(actor, %{person_identifier: full_invitee, status: "invited"},
                 reserve: full
               )

      assert {:error, :not_found} = Members.find_invited_identifier(actor, full_invitee)
      admitted = person_id()

      assert {:ok, %{user_id: ^admitted}} =
               Members.seat(actor, %{user_id: admitted, added_by: "x"}, reserve: fn -> :ok end)

      assert {:ok, 2} = Members.count_seats(actor)
    end

    test "a reserve: closure runs only once the athanor is found seatable" do
      archived = group!()

      {:ok, _} =
        Arca.SecurityTransitions.archive_athanor(server(), archived.id, verify: fn _ -> :ok end)

      test = self()

      reserve = fn ->
        send(test, :reserved)
        :ok
      end

      assert {:error, :unknown_athanor} =
               Members.seat(in_athanor("ath_missing"), %{user_id: person_id()}, reserve: reserve)

      assert {:error, :athanor_archived} =
               Members.seat(in_athanor(archived.id), %{user_id: person_id()}, reserve: reserve)

      refute_received :reserved
    end

    test "seat/3 declares reserve: alone, as a zero-arity function, and raises on anything else" do
      athanor = group!()
      actor = in_athanor(athanor.id)
      attrs = %{user_id: person_id(), added_by: "x"}

      for opts <- [
            [verify: fn -> :ok end],
            [reserve: :ok],
            [reserve: fn _ -> :ok end],
            [reserve: fn -> :ok end, also: fn -> :ok end]
          ] do
        assert_raise ArgumentError, fn -> Members.seat(actor, attrs, opts) end

        assert_raise ArgumentError, fn ->
          Members.seat(%Prima.Actor{athanor_id: nil}, attrs, opts)
        end
      end

      assert {:ok, 0} = Members.count_seats(actor)
    end

    test "an invitation is withdrawn by id while it is one; a seat, a grant, another athanor's row or no row is not found and stays" do
      a = group!()
      b = group!()
      user = person_id()
      invitee = identifier()
      {:ok, seat} = Members.seat(in_athanor(a.id), %{user_id: user, added_by: "x"})
      grant = grant!(user)

      {:ok, invitation} =
        Members.seat(in_athanor(a.id), %{
          person_identifier: invitee,
          status: "invited",
          added_by: "x"
        })

      for {actor, id} <- [
            {in_athanor(a.id), "mem_nobody"},
            {in_athanor(a.id), seat.id},
            {in_athanor(a.id), grant.id},
            {in_athanor(b.id), invitation.id}
          ] do
        assert {:error, :not_found} = Members.withdraw_invitation(actor, id)
      end

      assert {:ok, 2} = Members.count_seats(in_athanor(a.id))
      assert {:ok, [^user]} = Members.active_user_ids(in_athanor(a.id))
      assert {:ok, %{id: grant_id}} = Members.find_platform(server(), user)
      assert grant_id == grant.id

      # The row that goes is the invitation the id names, and it goes once.
      id = invitation.id

      assert {:ok, %{id: ^id, status: "invited", person_identifier: ^invitee}} =
               Members.withdraw_invitation(in_athanor(a.id), id)

      assert {:error, :not_found} = Members.withdraw_invitation(in_athanor(a.id), id)
      assert {:error, :not_found} = Members.find_invited_identifier(in_athanor(a.id), invitee)
      assert {:ok, 1} = Members.count_seats(in_athanor(a.id))
    end
  end

  describe "across tenants" do
    test "the platform grant, written inside a transaction, names no athanor and is read back as the person's" do
      user = person_id()
      assert {:ok, :ok} = Arca.Repo.transaction(fn -> Members.grant_platform!(user) end)

      assert {:ok, row} = Members.find_platform(server(), user)
      assert row.athanor_id == nil
      assert row.scope == "platform"
      assert {:ok, %{id: id}} = Members.get(server(), row.id)
      assert id == row.id
      assert Enum.any?(elem(Members.list_platform(server()), 1), &(&1.id == row.id))
    end

    test "a person's rows are read across every athanor they sat in" do
      a = group!()
      b = group!()
      user = person_id()
      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: user, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: user, added_by: "x"})
      _grant = grant!(user)

      assert {:ok, rows} = Members.list_active_for_user(server(), user)
      assert length(rows) == 3

      assert {:ok, true} = shared?(a.id, user)
    end

    test "two people share an athanor only while both seats are active and the athanor is" do
      athanor = group!()
      alice = person_id()
      bob = person_id()
      carol = person_id()
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: alice, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: bob, added_by: "x"})

      assert {:ok, true} = Members.shared_athanor?(server(), alice, bob)
      assert {:ok, false} = Members.shared_athanor?(server(), alice, carol)

      {:ok, _} =
        Arca.SecurityTransitions.archive_athanor(server(), athanor.id, verify: fn _ -> :ok end)

      assert {:ok, false} = Members.shared_athanor?(server(), alice, bob)
    end
  end

  describe "people_sharing/2" do
    test "lists everyone seated with the caller as their users rows name them, and never the caller" do
      athanor = group!()
      alice = person!()
      bob = person!(%{display_name: "Bob"})
      carol = person!()
      for user <- [alice, bob, carol], do: sit!(athanor, user)

      assert {:ok, people} = Members.people_sharing(server(), alice.id)

      assert Enum.sort_by(people, & &1.user_id) ==
               Enum.sort_by(
                 [
                   %{user_id: bob.id, display_name: "Bob", email: bob.email},
                   %{user_id: carol.id, display_name: nil, email: carol.email}
                 ],
                 & &1.user_id
               )

      # Alone in a room, the caller sits with nobody.
      lonely = person!()
      sit!(group!(), lonely)
      assert {:ok, []} = Members.people_sharing(server(), lonely.id)
    end

    test "a person in two of the caller's athanors is listed once" do
      a = group!()
      b = group!()
      alice = person!()
      bob = person!()
      for athanor <- [a, b], user <- [alice, bob], do: sit!(athanor, user)

      assert {:ok, [%{user_id: bob_id}]} = Members.people_sharing(server(), alice.id)
      assert bob_id == bob.id
    end

    test "a person is listed once, by their users row, however their seats differ" do
      a = group!()
      b = group!()
      alice = person!()
      bob = person!(%{display_name: "Bob"})
      for athanor <- [a, b], do: sit!(athanor, alice)

      # The schema lets an active seat carry a person identifier of its
      # own, a writer and its times, and Bob's two seats differ in every
      # one of them.
      early = ~U[2026-01-01 00:00:00.000000Z]
      late = ~U[2026-06-01 00:00:00.000000Z]

      row!(a, bob,
        person_identifier: "per_" <> Prima.Digest.sha256_hex("bob-a-#{uniq()}"),
        added_by: alice.id,
        created_at: early,
        updated_at: early
      )

      row!(b, bob,
        person_identifier: "per_" <> Prima.Digest.sha256_hex("bob-b-#{uniq()}"),
        added_by: "system",
        created_at: late,
        updated_at: late
      )

      assert {:ok, [bob_row]} = Members.people_sharing(server(), alice.id)
      assert bob_row == %{user_id: bob.id, display_name: "Bob", email: bob.email}
    end

    test "an archived athanor is no room, from either side" do
      archived = group!()
      kept = group!()
      alice = person!()
      bob = person!()
      carol = person!()
      for user <- [alice, bob], do: sit!(archived, user)
      for user <- [alice, carol], do: sit!(kept, user)

      {:ok, _} =
        Arca.SecurityTransitions.archive_athanor(server(), archived.id, verify: fn _ -> :ok end)

      assert {:ok, [%{user_id: carol_id}]} = Members.people_sharing(server(), alice.id)
      assert carol_id == carol.id
      assert {:ok, []} = Members.people_sharing(server(), bob.id)
    end

    test "an invitation is no seat, the caller's or anyone else's" do
      mine = group!()
      theirs = group!()
      alice = person!()
      dave = person!()
      sit!(mine, alice)
      sit!(theirs, dave)

      # A person invited into the caller's athanor is not seated there yet.
      {:ok, _} =
        Members.seat(in_athanor(mine.id), %{
          person_identifier: identifier(),
          status: "invited",
          added_by: "x"
        })

      # The caller invited into another athanor sits with nobody there.
      {:ok, _} =
        Members.seat(in_athanor(theirs.id), %{
          person_identifier: identifier(),
          status: "invited",
          added_by: "x"
        })

      assert {:ok, []} = Members.people_sharing(server(), alice.id)
      assert {:ok, []} = Members.people_sharing(server(), dave.id)
    end

    test "a row that is not active seats no one, even one naming its person" do
      mine = group!()
      theirs = group!()
      alice = person!()
      bob = person!()
      dave = person!()
      sit!(mine, alice)
      sit!(theirs, dave)

      # An invited row naming a person rather than an address, on either
      # side: only the status says it is no seat.
      row!(mine, bob, status: "invited")
      row!(theirs, alice, status: "invited")

      assert {:ok, []} = Members.people_sharing(server(), alice.id)
      assert {:ok, []} = Members.people_sharing(server(), bob.id)
      assert {:ok, []} = Members.people_sharing(server(), dave.id)
    end

    test "a platform grant is no shared room, even one naming an athanor" do
      room = group!()
      other = group!()
      alice = person!()
      bob = person!()
      dave = person!()
      sit!(room, alice)
      sit!(other, dave)

      # Both hold the operator grant, which names no athanor.
      for user <- [alice, bob], do: grant!(user.id)

      # A platform row naming an athanor, on either side: only the scope
      # says it is no seat.
      row!(room, bob, scope: "platform")
      row!(other, alice, scope: "platform")

      assert {:ok, []} = Members.people_sharing(server(), alice.id)
      assert {:ok, []} = Members.people_sharing(server(), bob.id)
    end

    test "an actor other than the platform's is refused before any query" do
      watch_queries!()

      # The server narrowed to one athanor, and the person asking as themself.
      for actor <- [
            in_athanor("ath_somewhere"),
            %Prima.Actor{athanor_id: "ath_somewhere", scope: :athanor, user_id: "usr_1"}
          ] do
        assert {:error, :cross_tenant} = Members.people_sharing(actor, "usr_1")
      end

      refute_received :queried

      # The probe is live: the platform's actor does query.
      assert {:ok, []} = Members.people_sharing(server(), "usr_nobody")
      assert_received :queried
    end
  end

  defp uniq, do: System.unique_integer([:positive])

  defp person!(overrides \\ %{}) do
    n = uniq()
    now = DateTime.utc_now()

    user_attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
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
      Arca.Test.People.mint(server(), user_attrs, %{
        key: "github|https://github.com|m#{n}",
        provider: "github",
        issuer: "https://github.com",
        subject: "m#{n}",
        first_seen_at: now,
        last_seen_at: now
      })

    user
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("inv-#{uniq()}")

  # The platform row for `user_id`, as the first person's mint writes it.
  defp grant!(user_id) do
    {:ok, :ok} = Arca.Repo.transaction(fn -> Members.grant_platform!(user_id) end)
    {:ok, grant} = Members.find_platform(server(), user_id)
    grant
  end

  defp shared?(athanor_id, user_id) do
    with {:ok, ids} <- Members.active_user_ids(in_athanor(athanor_id)) do
      {:ok, user_id in ids}
    end
  end

  defp sit!(athanor, user) do
    {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user.id, added_by: "x"})
    :ok
  end

  # A membership row of `user` in `athanor`, an active seat unless
  # `overrides` say otherwise, written as a row: past the changeset, which
  # would clear what an active seat, an invitation or a platform row may
  # not carry, but within what the schema admits.
  defp row!(athanor, user, overrides) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Membership, [
        Map.merge(
          %{
            id: Prima.UUID7.generate_id("mem"),
            athanor_id: athanor.id,
            user_id: user.id,
            scope: "athanor",
            status: "active",
            added_by: "x",
            created_at: now,
            updated_at: now
          },
          Map.new(overrides)
        )
      ])

    :ok
  end
end

defmodule Arca.MembersLockTest do
  @moduledoc """
  The membership writers under two real connections, outside the
  sandbox. Every writer of a row naming a person — a seat, an identifier
  claim, the platform grant — takes the person's lock first, so none
  overtakes a leave or a denial holding them: on PostgreSQL by waiting on
  the row, on SQLite by waiting at the lock its transaction takes at
  entry. A withdrawal waiting behind an uncommitted claim of its
  invitation meets the seat the claim made, and deletes nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Members
  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, User}
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    {:ok, user} =
      unboxed(fn ->
        Arca.Test.People.mint(
          server(),
          %{
            id: id,
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

    {:ok, user: user}
  end

  test "a withdrawal waiting behind an uncommitted claim of the invitation deletes nothing", %{
    user: user
  } do
    n = System.unique_integer([:positive])
    invitee = "per_" <> Prima.Digest.sha256_hex("lock-withdraw-#{n}")

    {:ok, athanor} =
      unboxed(fn ->
        Arca.Athanors.insert(server(), %{
          kind: "group",
          name: "W#{n}",
          slug: "mem-withdraw-#{n}",
          created_by: "system"
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor.id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor.id))
      end)
    end)

    # An identifier invitation is fenced by the member's slot; no claimant
    # runs here, so none is held and none is asked for.
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, false)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    {:ok, invitation} =
      unboxed(fn ->
        Members.seat(in_athanor(athanor.id), %{
          person_identifier: invitee,
          status: "invited",
          added_by: "x"
        })
      end)

    test = self()

    # The claim's statement, held uncommitted: the invited row is already
    # the seat inside this transaction.
    claimer =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            {1, _} =
              Arca.Repo.update_all(where(Membership, id: ^invitation.id, status: "invited"),
                set: [user_id: user.id, status: "active", person_identifier: nil]
              )

            send(test, :claimed)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :claimed, 5_000

    withdrawer =
      Task.async(fn ->
        unboxed(fn -> Members.withdraw_invitation(in_athanor(athanor.id), invitation.id) end)
      end)

    refute Task.yield(withdrawer, 300), "the withdrawal decided while the claim was uncommitted"
    send(claimer.pid, :commit)
    assert {:ok, :ok} = Task.await(claimer, 25_000)
    assert {:error, :not_found} = Task.await(withdrawer, 25_000)

    assert {:ok, [seated]} = unboxed(fn -> Members.active_user_ids(in_athanor(athanor.id)) end)
    assert seated == user.id
  end

  test "a seat, a claim and the grant each wait for whoever holds the person", %{user: user} do
    # An identifier invitation and its claim are fenced by the member's
    # slot; no claimant runs here, so none is held and none is asked for.
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, false)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    n = System.unique_integer([:positive])
    identifier = "per_" <> Prima.Digest.sha256_hex("lock-#{n}")

    [seated, by_identifier] =
      ids =
      for i <- 1..2 do
        {:ok, athanor} =
          unboxed(fn ->
            Arca.Athanors.insert(server(), %{
              kind: "group",
              name: "L#{n}-#{i}",
              slug: "mem-lock-#{n}-#{i}",
              created_by: "system"
            })
          end)

        athanor.id
      end

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(m in Membership, where: m.athanor_id in ^ids))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^ids))
      end)
    end)

    # The invitation a claim takes names no person, so writing it locks
    # none.
    {:ok, _} =
      unboxed(fn ->
        Members.seat(in_athanor(by_identifier), %{
          person_identifier: identifier,
          status: "invited",
          added_by: "x"
        })
      end)

    writers = [
      seat: fn -> Members.seat(in_athanor(seated), %{user_id: user.id, added_by: "x"}) end,
      identifier_claim: fn ->
        Members.activate_invited_identifier(server(), user.id, identifier, DateTime.utc_now())
      end,
      grant: fn -> Arca.Repo.transaction(fn -> Members.grant_platform!(user.id) end) end
    ]

    for {name, write} <- writers do
      holder = hold_person(user.id)
      writer = Task.async(fn -> unboxed(write) end)
      refute Task.yield(writer, 300), "#{name} was written while the person was held"
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 25_000)
      assert {:ok, _} = Task.await(writer, 25_000), "#{name}"
    end

    unboxed(fn ->
      seats =
        Arca.Repo.all(from(m in Membership, where: m.user_id == ^user.id, select: m.athanor_id))

      assert Enum.sort(seats) == Enum.sort([nil | ids])
    end)
  end

  # SQLite takes its one write lock as the transaction starts, before the
  # closure, so there is no row lock to observe.
  @tag :postgres
  test "a reserve: closure runs with the person's and the athanor's rows locked", %{user: user} do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      unboxed(fn ->
        Arca.Athanors.insert(server(), %{
          kind: "group",
          name: "R#{n}",
          slug: "mem-reserve-#{n}",
          created_by: "system"
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(m in Membership, where: m.athanor_id == ^athanor.id))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor.id))
      end)
    end)

    test = self()

    reserve = fn ->
      send(test, {:reserving, self()})

      receive do
        :go -> :ok
      end
    end

    seat =
      Task.async(fn ->
        unboxed(fn ->
          Members.seat(in_athanor(athanor.id), %{user_id: user.id, added_by: "x"},
            reserve: reserve
          )
        end)
      end)

    assert_receive {:reserving, seating}, 15_000

    for {table, id} <- [{"users", user.id}, {"athanors", athanor.id}] do
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               unboxed(fn ->
                 Arca.Repo.query("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE NOWAIT", [id])
               end),
             "the #{table} row was not locked while the closure ran"
    end

    send(seating, :go)
    assert {:ok, %{user_id: user_id}} = Task.await(seat, 25_000)
    assert user_id == user.id
  end

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  # A transaction holding the person's row, as a leave or a denial holds it
  # (`Arca.SecurityTransitions`), until the test says release.
  defp hold_person(user_id) do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(u in User, where: u.id == ^user_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()

            send(test, :person_held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :person_held, 5_000
    holder
  end
end

defmodule Arca.MembersIdentifierInvitesTest do
  @moduledoc """
  Invitations held for a person identifier: an identifier names every
  invited row, and whoever proves the identity claims
  every invitation it holds, once. Writing and claiming one widens who
  may sit in an athanor, so each proves first that this member still owns
  its slot, and a stale member is refused `:not_owner`.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{Athanors, ControlPlane, Members}
  alias Arca.Schemas.CellLease

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, slot: hold_slot!()}
  end

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp group! do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Athanors.insert(server(), %{
        kind: "group",
        name: "G#{n}",
        slug: "mem-id-#{n}",
        created_by: "system"
      })

    athanor
  end

  defp person_id, do: "usr_#{System.unique_integer([:positive])}"

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")

  test "an invitation names an identifier" do
    athanor = group!()
    id = identifier()

    assert {:error, {:invalid, %{person_identifier: _}}} =
             Members.seat(in_athanor(athanor.id), %{status: "invited", added_by: "x"})

    assert {:error, {:invalid, %{person_identifier: _}}} =
             Members.seat(in_athanor(athanor.id), %{
               person_identifier: "usr_not_an_identifier",
               status: "invited",
               added_by: "x"
             })

    assert {:ok, %{person_identifier: ^id, user_id: nil}} =
             Members.seat(in_athanor(athanor.id), %{
               person_identifier: id,
               status: "invited",
               added_by: "x"
             })

    assert {:error, :conflict} =
             Members.seat(in_athanor(athanor.id), %{
               person_identifier: id,
               status: "invited",
               added_by: "x"
             })

    assert {:ok, %{person_identifier: ^id}} =
             Members.find_invited_identifier(in_athanor(athanor.id), id)

    assert {:ok, [%{status: "invited", person_identifier: ^id}]} =
             Members.list(in_athanor(athanor.id))
  end

  test "an active row names its person and carries no identifier" do
    athanor = group!()
    user = person_id()

    assert {:ok, %{person_identifier: nil}} =
             Members.seat(in_athanor(athanor.id), %{
               user_id: user,
               person_identifier: identifier(),
               added_by: "x"
             })
  end

  test "activation claims every invitation the identifier holds, once" do
    a = group!()
    b = group!()
    user = person_id()
    id = identifier()

    for athanor <- [a, b] do
      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{
          person_identifier: id,
          status: "invited",
          added_by: "x"
        })
    end

    assert {:ok, claimed} =
             Members.activate_invited_identifier(server(), user, id, DateTime.utc_now())

    assert Enum.sort(claimed) == Enum.sort([a.id, b.id])
    assert {:ok, [%{status: "active", person_identifier: nil}]} = Members.list(in_athanor(a.id))

    assert {:ok, []} =
             Members.activate_invited_identifier(server(), user, id, DateTime.utc_now())

    assert {:error, :cross_tenant} =
             Members.activate_invited_identifier(in_athanor(a.id), user, id, DateTime.utc_now())
  end

  test "a withdrawn identifier invitation claims nothing" do
    athanor = group!()
    id = identifier()

    {:ok, _} =
      Members.seat(in_athanor(athanor.id), %{
        person_identifier: id,
        status: "invited",
        added_by: "x"
      })

    assert {:ok, [withdrawn]} = Members.withdraw_invites_for_identifier(server(), id)
    assert withdrawn == athanor.id

    assert {:ok, []} =
             Members.activate_invited_identifier(server(), person_id(), id, DateTime.utc_now())
  end

  test "a stale member writes no identifier invitation and claims none", %{slot: slot} do
    athanor = group!()
    id = identifier()

    {:ok, _} =
      Members.seat(in_athanor(athanor.id), %{
        person_identifier: id,
        status: "invited",
        added_by: "x"
      })

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    assert {:error, :not_owner} =
             Members.seat(in_athanor(group!().id), %{
               person_identifier: identifier(),
               status: "invited",
               added_by: "x"
             })

    assert {:error, :not_owner} =
             Members.activate_invited_identifier(server(), person_id(), id, DateTime.utc_now())

    assert {:ok, [%{status: "invited", person_identifier: ^id}]} =
             Members.list(in_athanor(athanor.id))
  end
end
