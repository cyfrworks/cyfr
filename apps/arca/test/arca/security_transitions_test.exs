# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Fixtures do
  @moduledoc false
  # Rows the transition tests act on, written through the storage facades
  # as the layer above writes them.

  import Ecto.Query

  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, User}

  def server, do: Cyfr.Actor.system()
  def admit, do: fn _rows -> :ok end
  def uniq, do: System.unique_integer([:positive])

  def person!(overrides \\ %{}) do
    n = uniq()
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Users.mint(
        server(),
        Map.merge(
          %{
            id: Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix()),
            provider: "github",
            email: "st#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          overrides
        ),
        %{
          key: "github|https://github.com|st#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "st#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    user
  end

  # A person with their own estate, seated in it.
  def owner! do
    user = person!()
    n = uniq()

    {:ok, estate} =
      Arca.Athanors.insert(server(), %{
        kind: "person",
        name: "Own #{n}",
        slug: "own-#{n}",
        owner_user_id: user.id,
        created_by: user.id
      })

    {:ok, user} = Arca.Users.update(server(), user, %{personal_athanor_id: estate.id})
    seat!(estate.id, user.id)
    {user, estate}
  end

  def group!(attrs \\ %{}) do
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(
        server(),
        Map.merge(%{kind: "group", name: "G#{n}", slug: "st-g-#{n}", created_by: "system"}, attrs)
      )

    athanor
  end

  def seat!(athanor_id, user_id) do
    {:ok, row} =
      Arca.Members.seat(Cyfr.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})

    row
  end

  def invite!(athanor_id, email) do
    {:ok, row} =
      Arca.Members.seat(Cyfr.Actor.in_athanor(athanor_id), %{
        email: email,
        status: "invited",
        added_by: "x"
      })

    row
  end

  def session!(user_id, athanor_id \\ nil) do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: user_id,
          provider: "github",
          athanor_id: athanor_id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        Arca.Test.Actor.issuance(user_id)
      )

    hash
  end

  def key!(athanor_id, created_by) do
    n = uniq()
    hash = :crypto.hash(:sha256, "st-key-#{n}")

    :ok =
      Arca.ApiKeyStorage.create_key(
        %{
          name: "k#{n}",
          key_hash: hash,
          key_prefix: "cyfr_sk_st",
          type: "service",
          created_by: created_by,
          athanor_id: athanor_id
        },
        Arca.Test.Actor.issuance(created_by)
      )

    {:ok, %{id: id}} = Arca.ApiKeyStorage.get_key_by_hash(hash)
    id
  end

  def user(id), do: Arca.Repo.get(User, id)
  def athanor(id), do: Arca.Repo.get(Athanor, id)
  def session?(hash), do: Arca.Repo.exists?(where(Session, token_hash: ^hash))
  def revoked?(key_id), do: Arca.Repo.get(ApiKey, key_id).revoked
  def seats(user_id), do: Arca.Repo.all(where(Membership, user_id: ^user_id))
  def membership(id), do: Arca.Repo.get(Membership, id)

  # A trigger that makes one statement fail inside the transition, spelled
  # per adapter. The sandbox rolls it back with the test.
  def fail_on!(table, event) do
    name = "st_fail_#{table}_#{String.downcase(event)}"

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

    name
  end

  def clear_failure!(name) do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("DROP TRIGGER #{name}")

      _postgres ->
        table =
          Regex.replace(~r/_(delete|update)$/, String.replace_prefix(name, "st_fail_", ""), "")

        Arca.Repo.query!("DROP TRIGGER #{name} ON #{table}")
        Arca.Repo.query!("DROP FUNCTION #{name}()")
    end
  end
end

defmodule Arca.SecurityTransitionsTest do
  @moduledoc """
  The four standing transitions, each one transaction: what a denial
  retires, what an allow restores and what it never does, archive and
  reopen, the generation every real change raises, and a failed statement
  rolling back everything — the injected session DELETE and key UPDATE
  failures included, after which an allow revives nothing.
  """

  use ExUnit.Case, async: false

  import Arca.SecurityTransitions.Fixtures

  alias Arca.SecurityTransitions

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  describe "deny_user/3" do
    test "retires every credential, seat, invitation and follow, and archives what it must" do
      {user, own} = owner!()
      open = group!()
      pair = group!(%{roster: "frozen"})
      shared = group!()
      peer = person!()

      for athanor <- [open, pair, shared], do: seat!(athanor.id, user.id)
      seat!(pair.id, peer.id)
      seat!(shared.id, peer.id)
      invitation = invite!(shared.id, user.email)

      :ok =
        Arca.ThreadSubscriptionStorage.follow(Cyfr.Actor.in_athanor(open.id), "thr_1", user.id)

      own_session = session!(user.id, own.id)
      other_session = session!(user.id)
      own_key = key!(own.id, user.id)
      made_elsewhere = key!(shared.id, user.id)
      pair_key = key!(pair.id, peer.id)
      shared_key = key!(shared.id, peer.id)

      assert {:ok, change} =
               SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert change.transitioned
      assert change.user_generation == 2
      assert user(user.id).status == "denied"
      assert user(user.id).security_generation == 2

      # Archived: the person's own estate, the frozen pair they sat in, the
      # open group they leave empty; the group a peer still holds stands.
      assert change.archived_athanor_ids == Enum.sort([own.id, pair.id, open.id])
      for id <- change.archived_athanor_ids, do: assert(athanor(id).status == "archived")
      assert change.athanor_generations == Map.new(change.archived_athanor_ids, &{&1, 2})
      assert athanor(shared.id).status == "active"
      assert athanor(shared.id).security_generation == 1

      # The hashes and ids are the ones the statements removed.
      assert Enum.sort(change.revoked_session_hashes) == Enum.sort([own_session, other_session])
      refute session?(own_session) or session?(other_session)

      assert Enum.sort(change.revoked_api_key_ids) ==
               Enum.sort([own_key, made_elsewhere, pair_key])

      assert revoked?(own_key) and revoked?(made_elsewhere) and revoked?(pair_key)
      refute revoked?(shared_key)

      assert seats(user.id) == []
      assert length(change.removed_membership_ids) == 4
      assert [%{id: invitation_id}] = change.withdrawn_invitations
      assert invitation_id == invitation.id
      assert change.unfollowed == 1
      assert change.member_user_ids[pair.id] == [peer.id]
    end

    test "a repeated denial moves no generation and still checks what it retires" do
      {user, own} = owner!()
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      # Something that survived a lost write: a session and a key issued
      # around the first denial.
      straggler = session!(user.id)
      key = key!(own.id, user.id)

      assert {:ok, change} = SecurityTransitions.deny_user(server(), user.id, verify: admit())
      refute change.transitioned
      assert change.user_generation == 2
      assert change.archived_athanor_ids == []
      assert change.revoked_session_hashes == [straggler]
      assert change.revoked_api_key_ids == [key]
      assert user(user.id).security_generation == 2
      assert athanor(own.id).security_generation == 2
    end

    test "a person with no own estate is denied; a pointer to no row is refused" do
      plain = person!()

      assert {:ok, %{archived_athanor_ids: []}} =
               SecurityTransitions.deny_user(server(), plain.id, verify: admit())

      dangling = person!()
      {:ok, _} = Arca.Users.update(server(), dangling, %{personal_athanor_id: "ath_nowhere"})
      session = session!(dangling.id)

      assert {:error, :dangling_personal_athanor} =
               SecurityTransitions.deny_user(server(), dangling.id, verify: admit())

      assert user(dangling.id).status == "active"
      assert session?(session)
    end

    test "the caller's refusal rolls back everything, with its reason" do
      {user, own} = owner!()
      session = session!(user.id)
      key = key!(own.id, user.id)

      assert {:error, :operator_said_no} =
               SecurityTransitions.deny_user(server(), user.id,
                 verify: fn %{user: %{id: id}, archive: archive} ->
                   send(self(), {:asked, id, archive})
                   {:error, :operator_said_no}
                 end
               )

      assert_received {:asked, id, [own_id]}
      assert id == user.id and own_id == own.id
      assert user(user.id).status == "active"
      assert athanor(own.id).status == "active"
      assert session?(session)
      refute revoked?(key)
    end

    test "an unknown person and a non-system actor are refused before anything moves" do
      assert {:error, :not_found} =
               SecurityTransitions.deny_user(server(), "usr_nobody", verify: admit())

      user = person!()

      assert {:error, :cross_tenant} =
               SecurityTransitions.deny_user(Cyfr.Actor.in_athanor("ath_test"), user.id,
                 verify: admit()
               )

      assert user(user.id).status == "active"
    end
  end

  describe "an injected failure inside a denial" do
    for {table, event, label} <- [
          {"sessions", "DELETE", "the session DELETE"},
          {"api_keys", "UPDATE", "the key UPDATE"},
          {"memberships", "DELETE", "the membership DELETE"},
          {"thread_subscriptions", "DELETE", "the follow DELETE"},
          {"athanors", "UPDATE", "the estate UPDATE"},
          {"users", "UPDATE", "the person UPDATE"}
        ] do
      test "#{label} failing rolls the denial back, and an allow then revives nothing" do
        {user, own} = owner!()
        session = session!(user.id, own.id)
        key = key!(own.id, user.id)

        :ok =
          Arca.ThreadSubscriptionStorage.follow(Cyfr.Actor.in_athanor(own.id), "thr_f", user.id)

        failure = fail_on!(unquote(table), unquote(event))

        assert {:error, :database_error} =
                 SecurityTransitions.deny_user(server(), user.id, verify: admit())

        # Nothing committed: no denial with a live credential, and no
        # half-archived estate.
        assert user(user.id).status == "active"
        assert user(user.id).security_generation == 1
        assert athanor(own.id).status == "active"
        assert session?(session)
        refute revoked?(key)
        assert length(seats(user.id)) == 1

        # An allow over the failed denial has nothing to restore and moves
        # nothing.
        assert {:ok, %{transitioned: false, user_generation: 1}} =
                 SecurityTransitions.allow_user(server(), user.id, verify: admit())

        # The retry, once the statement can run, retires everything; the
        # allow after it restores the standing and none of the credentials.
        clear_failure!(failure)

        assert {:ok, %{transitioned: true}} =
                 SecurityTransitions.deny_user(server(), user.id, verify: admit())

        assert {:ok, allowed} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
        assert allowed.user_generation == 3
        refute session?(session)
        assert revoked?(key)
        assert athanor(own.id).status == "active"
        assert athanor(own.id).security_generation == 3
      end
    end
  end

  describe "allow_user/3" do
    test "restores standing, the own estate and a new seat in it, and nothing else" do
      {user, own} = owner!()
      group = group!()
      seat!(group.id, user.id)
      peer = person!()
      seat!(group.id, peer.id)
      key = key!(own.id, user.id)
      {:ok, denied} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      [old_seat] =
        for %{athanor_id: id} = row <- denied.removed_memberships, id == own.id, do: row

      assert {:ok, change} = SecurityTransitions.allow_user(server(), user.id, verify: admit())
      assert change.transitioned
      assert change.user_generation == 3
      assert change.reopened_athanor_ids == [own.id]
      assert change.athanor_generations == %{own.id => 3}
      assert [seated] = change.seated_membership_ids
      refute seated == old_seat.id

      assert user(user.id).status == "active"
      assert athanor(own.id).status == "active"
      assert Enum.map(seats(user.id), & &1.athanor_id) == [own.id]
      assert revoked?(key)
      assert change.revoked_session_hashes == [] and change.revoked_api_key_ids == []
    end

    test "the caller's cap refusal leaves the person denied and the estate archived" do
      {user, own} = owner!()
      {:ok, _} = SecurityTransitions.deny_user(server(), user.id, verify: admit())

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               SecurityTransitions.allow_user(server(), user.id,
                 verify: fn %{athanor: %{status: "archived"}} ->
                   {:error, {:limit_reached, :max_athanors, 1}}
                 end
               )

      assert user(user.id).status == "denied"
      assert user(user.id).security_generation == 2
      assert athanor(own.id).status == "archived"
      assert seats(user.id) == []
    end
  end

  describe "archive_athanor/3 and unarchive_athanor/3" do
    test "an archive revokes the estate's keys with it; a reopen revokes none back" do
      group = group!()
      member = person!()
      seat!(group.id, member.id)
      key = key!(group.id, member.id)

      assert {:ok, archived} =
               SecurityTransitions.archive_athanor(server(), group.id, verify: admit())

      assert archived.transitioned
      assert archived.archived_athanor_ids == [group.id]
      assert archived.athanor_generations == %{group.id => 2}
      assert archived.revoked_api_key_ids == [key]
      assert archived.member_user_ids == %{group.id => [member.id]}
      assert [%{status: "archived", security_generation: 2}] = archived.athanors

      # Idempotent: no second generation, the keys checked again.
      assert {:ok, again} =
               SecurityTransitions.archive_athanor(server(), group.id, verify: admit())

      refute again.transitioned
      assert athanor(group.id).security_generation == 2

      assert {:ok, reopened} =
               SecurityTransitions.unarchive_athanor(server(), group.id, verify: admit())

      assert reopened.reopened_athanor_ids == [group.id]
      assert athanor(group.id).status == "active"
      assert athanor(group.id).security_generation == 3
      assert revoked?(key)

      assert {:ok, %{transitioned: false}} =
               SecurityTransitions.unarchive_athanor(server(), group.id, verify: admit())
    end

    test "an injected key UPDATE failure leaves the estate open and its keys live" do
      group = group!()
      key = key!(group.id, person!().id)
      failure = fail_on!("api_keys", "UPDATE")

      assert {:error, :database_error} =
               SecurityTransitions.archive_athanor(server(), group.id, verify: admit())

      assert athanor(group.id).status == "active"
      assert athanor(group.id).security_generation == 1
      refute revoked?(key)
      clear_failure!(failure)
    end

    test "the caller decides, over the locked row" do
      group = group!(%{roster: "frozen"})
      {:ok, _} = SecurityTransitions.archive_athanor(server(), group.id, verify: admit())

      assert {:error, :frozen_is_final} =
               SecurityTransitions.unarchive_athanor(server(), group.id,
                 verify: fn %{athanor: %{roster: "frozen"}} -> {:error, :frozen_is_final} end
               )

      assert athanor(group.id).status == "archived"

      assert {:error, :not_found} =
               SecurityTransitions.archive_athanor(server(), "ath_nowhere", verify: admit())
    end
  end

  describe "the standing columns" do
    test "ordinary updates refuse them as read-only" do
      user = person!()

      assert {:error, {:invalid, %{security_generation: ["is read-only"]}}} =
               Arca.Users.update(server(), user, %{security_generation: 9})

      assert {:error, {:invalid, %{status: ["is read-only"]}}} =
               Arca.Users.update(server(), user, %{status: "denied"})

      group = group!()

      assert {:error, {:invalid, %{security_generation: ["is read-only"]}}} =
               Arca.Athanors.update(Cyfr.Actor.in_athanor(group.id), %{security_generation: 9})

      assert {:error, {:invalid, %{status: ["is read-only"]}}} =
               Arca.Athanors.update(Cyfr.Actor.in_athanor(group.id), %{status: "archived"})

      assert {:error, {:invalid, %{security_generation: ["is read-only"]}}} =
               Arca.Athanors.set(Cyfr.Actor.in_athanor(group.id), security_generation: 9)

      assert user(user.id).security_generation == 1
      assert athanor(group.id).security_generation == 1
    end
  end
end

defmodule Arca.SecurityTransitionsLockTest do
  @moduledoc """
  The transitions under two real connections, outside the sandbox: a
  transition waiting behind another acts on what that one committed — on
  PostgreSQL by waiting on the row, on SQLite by waiting at its own BEGIN
  — and never on a read taken before the wait; and a denial whose
  membership set moves while it locks the estates runs again on the set
  as it now stands.
  """

  use ExUnit.Case, async: false

  require Arca.Repo.Errors

  import Ecto.Query

  import Arca.SecurityTransitions.Fixtures,
    only: [server: 0, admit: 0, uniq: 0]

  alias Arca.Schemas.{ApiKey, Athanor, ExternalIdentity, Membership, Session, User}
  alias Arca.SecurityTransitions
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    n = uniq()
    now = DateTime.utc_now()
    user_id = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())
    own_id = Cyfr.UUID7.generate_id("ath")

    unboxed(fn ->
      {:ok, _} =
        Arca.Users.mint(
          server(),
          %{
            id: user_id,
            provider: "github",
            email: "stl#{n}@example.com",
            email_verified: true,
            personal_athanor_id: own_id,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|stl#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "stl#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )

      {:ok, _} =
        Arca.Athanors.insert(server(), %{
          id: own_id,
          kind: "person",
          name: "Own #{n}",
          slug: "stl-own-#{n}",
          owner_user_id: user_id,
          created_by: user_id
        })
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(Session, user_id: ^user_id))
        Arca.Repo.delete_all(where(ApiKey, created_by: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)

      remove_estates!([own_id])
    end)

    {:ok, user_id: user_id, own_id: own_id}
  end

  # The estates a case minted, named by the case before it runs anything,
  # with every row that names them.
  defp remove_estates!(ids) do
    unboxed(fn ->
      Arca.Repo.delete_all(from(m in Membership, where: m.athanor_id in ^ids))
      Arca.Repo.delete_all(from(k in ApiKey, where: k.athanor_id in ^ids))
      Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^ids))
    end)
  end

  defp group!(attrs \\ %{}) do
    n = uniq()

    {:ok, athanor} =
      unboxed(fn ->
        Arca.Athanors.insert(
          server(),
          Map.merge(
            %{name: "G#{n}", slug: "stl-g-#{n}", kind: "group", created_by: "system"},
            attrs
          )
        )
      end)

    athanor.id
  end

  defp seat(athanor_id, user_id) do
    unboxed(fn ->
      Arca.Members.seat(Cyfr.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
    end)
  end

  # A transition that stops inside its own transaction — every lock taken,
  # nothing written — until the test says go.
  defp paused(transition, id) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        apply(SecurityTransitions, transition, [
          server(),
          id,
          [
            verify: fn _rows ->
              send(test, {:holding, transition})

              receive do
                :go -> :ok
              end
            end
          ]
        ])
      end)
    end)
  end

  defp run(transition, id) do
    Task.async(fn ->
      unboxed(fn -> apply(SecurityTransitions, transition, [server(), id, [verify: admit()]]) end)
    end)
  end

  test "a denial waiting behind an allow acts on the allow's commit, not on its own read", %{
    user_id: user_id,
    own_id: own_id
  } do
    {:ok, _} =
      unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)

    allower = paused(:allow_user, user_id)
    assert_receive {:holding, :allow_user}, 5_000

    denier = run(:deny_user, user_id)
    refute Task.yield(denier, 300), "the denial decided while the allow held the person"

    send(allower.pid, :go)
    assert {:ok, %{transitioned: true, user_generation: 3}} = Task.await(allower, 25_000)

    # Had the denial acted on a read from before its wait, it would have
    # found the person already denied and moved nothing.
    assert {:ok, change} = Task.await(denier, 25_000)
    assert change.transitioned
    assert change.user_generation == 4
    assert change.archived_athanor_ids == [own_id]

    unboxed(fn ->
      assert Arca.Repo.get(User, user_id).status == "denied"
      assert Arca.Repo.get(Athanor, own_id).security_generation == 4
    end)
  end

  test "an allow waiting behind a denial acts on the denial's commit", %{
    user_id: user_id,
    own_id: own_id
  } do
    denier = paused(:deny_user, user_id)
    assert_receive {:holding, :deny_user}, 5_000

    allower = run(:allow_user, user_id)
    refute Task.yield(allower, 300), "the allow decided while the denial held the person"

    send(denier.pid, :go)
    assert {:ok, %{transitioned: true, user_generation: 2}} = Task.await(denier, 25_000)

    assert {:ok, change} = Task.await(allower, 25_000)
    assert change.transitioned
    assert change.user_generation == 3
    assert change.reopened_athanor_ids == [own_id]
  end

  # How long a killed client's transaction may hold its locks: the ceiling
  # the wait below stops at.
  @release_bound_ms 30_000

  test "a denial whose process dies before commit leaves everything it touched standing", %{
    user_id: user_id,
    own_id: own_id
  } do
    hash = :crypto.strong_rand_bytes(32)

    :ok =
      unboxed(fn ->
        Arca.SessionStorage.create_session(
          hash,
          %{
            user_id: user_id,
            provider: "github",
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          Arca.Test.Actor.issuance(user_id)
        )
      end)

    # Every lock taken and the policy asked, then the process is gone with
    # its transaction open.
    pid =
      spawn(fn ->
        unboxed(fn ->
          SecurityTransitions.deny_user(server(), user_id,
            verify: fn _rows -> Process.exit(self(), :kill) end
          )
        end)
      end)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    killed_at = System.monotonic_time(:millisecond)

    # The dead transaction's locks go when its connection is closed. Wait
    # for that as an event — a write from a fresh connection that gets the
    # person's row — bounded, rather than for a guessed interval.
    released_ms = await_release!(user_id, killed_at, @release_bound_ms)
    assert released_ms <= @release_bound_ms

    unboxed(fn ->
      assert Arca.Repo.get(User, user_id).status == "active"
      assert Arca.Repo.get(User, user_id).security_generation == 1
      assert Arca.Repo.get(Athanor, own_id).status == "active"
      assert Arca.Repo.exists?(where(Session, token_hash: ^hash))
    end)

    # And the next denial is not blocked by what the dead one held.
    assert {:ok, %{revoked_session_hashes: [^hash]}} =
             unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
  end

  # A write-then-rollback on the person's row from a fresh connection,
  # retried every 50 ms until it gets the row or the bound passes; answers
  # the milliseconds since `since`. On SQLite the probe waits at its own
  # BEGIN (up to the busy timeout), on PostgreSQL on the row lock.
  defp await_release!(user_id, since, bound_ms) do
    probe =
      try do
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            Arca.Repo.update_all(where(User, id: ^user_id), set: [updated_at: DateTime.utc_now()])
            Arca.Repo.rollback(:probed)
          end)
        end)
      rescue
        _busy in Arca.Repo.Errors.db_errors() -> :held
      end

    elapsed = System.monotonic_time(:millisecond) - since

    cond do
      probe == {:error, :probed} ->
        elapsed

      elapsed > bound_ms ->
        flunk("a killed client's transaction still held the person after #{elapsed} ms")

      true ->
        Process.sleep(50)
        await_release!(user_id, since, bound_ms)
    end
  end

  test "an archive and a reopen serialize, each acting on the other's commit", %{own_id: own_id} do
    test = self()

    archiver =
      Task.async(fn ->
        unboxed(fn ->
          SecurityTransitions.archive_athanor(server(), own_id,
            verify: fn _rows ->
              send(test, :archive_holds)

              receive do
                :go -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :archive_holds, 5_000

    reopener =
      Task.async(fn ->
        unboxed(fn ->
          SecurityTransitions.unarchive_athanor(server(), own_id, verify: admit())
        end)
      end)

    refute Task.yield(reopener, 300), "the reopen decided while the estate was held"
    send(archiver.pid, :go)
    assert {:ok, %{transitioned: true}} = Task.await(archiver, 25_000)
    assert {:ok, reopened} = Task.await(reopener, 25_000)
    assert reopened.transitioned
    assert reopened.athanor_generations == %{own_id => 3}
  end

  @tag :postgres
  test "a membership taken while a denial locks the estates is on the set it runs again on", %{
    user_id: user_id
  } do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      # One writer: the denial's immediate transaction admits no seat
      # between its plan and its locks, so there is no moved set to find.
      :ok
    else
      pair_id = group!(%{roster: "frozen"})
      on_exit(fn -> remove_estates!([pair_id]) end)
      test = self()

      # Hold the person's own estate: the denial plans without the pair,
      # then waits on this row while the pair's seat is written.
      holder =
        Task.async(fn ->
          unboxed(fn ->
            Arca.Repo.transaction(fn ->
              [_] =
                from(a in Athanor,
                  where: a.id == ^Arca.Repo.get(User, user_id).personal_athanor_id
                )
                |> Arca.QueryHelpers.for_update()
                |> Arca.Repo.all()

              send(test, :holding)

              receive do
                :seat -> :ok
              end

              {:ok, _} =
                Arca.Members.seat(Cyfr.Actor.in_athanor(pair_id), %{
                  user_id: user_id,
                  added_by: "x"
                })
            end)
          end)
        end)

      assert_receive :holding, 5_000

      denier =
        Task.async(fn ->
          unboxed(fn -> SecurityTransitions.deny_user(server(), user_id, verify: admit()) end)
        end)

      refute Task.yield(denier, 300)
      send(holder.pid, :seat)
      Task.await(holder, 25_000)

      assert {:ok, change} = Task.await(denier, 25_000)
      assert pair_id in change.archived_athanor_ids
      unboxed(fn -> assert Arca.Repo.get(Athanor, pair_id).status == "archived" end)
    end
  end

  @tag :postgres
  test "a set that moves on every attempt ends in a conflict, and nothing is written", %{
    user_id: user_id,
    own_id: own_id
  } do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      # One writer: no second connection can seat the person while the
      # denial holds the database, so the set cannot move.
      :ok
    else
      groups = for _ <- 1..3, do: group!()
      on_exit(fn -> remove_estates!(groups) end)
      {:ok, _} = seat(own_id, user_id)
      {:ok, agent} = Agent.start_link(fn -> groups end)

      # Every time the policy is asked, a second connection seats the
      # person in one more group: the set the denial planned has moved by
      # the time it would write.
      verify = fn _rows ->
        next = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
        {:ok, _} = Task.await(Task.async(fn -> seat(next, user_id) end), 25_000)
        :ok
      end

      assert {:error, :conflict} =
               unboxed(fn ->
                 SecurityTransitions.deny_user(server(), user_id, verify: verify)
               end)

      assert Agent.get(agent, & &1) == []

      unboxed(fn ->
        user = Arca.Repo.get(User, user_id)
        assert user.status == "active"
        assert user.security_generation == 1
        assert Arca.Repo.get(Athanor, own_id).status == "active"

        for id <- groups do
          assert Arca.Repo.get(Athanor, id).status == "active"
          assert Arca.Repo.get(Athanor, id).security_generation == 1
        end

        # The seats the second connection wrote stand; the denial wrote nothing.
        assert length(Arca.Repo.all(where(Membership, user_id: ^user_id))) == 4
      end)
    end
  end

  test "a seat into an estate a denial is archiving waits for it and is refused", %{
    user_id: user_id
  } do
    group_id = group!()
    on_exit(fn -> remove_estates!([group_id]) end)
    {:ok, _} = seat(group_id, user_id)

    other = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())
    on_exit(fn -> unboxed(fn -> Arca.Repo.delete_all(where(Membership, user_id: ^other)) end) end)

    # The person is the group's last member, so the denial archives it; it
    # holds the estate while its policy is asked.
    denier = paused(:deny_user, user_id)
    assert_receive {:holding, :deny_user}, 5_000

    seater = Task.async(fn -> seat(group_id, other) end)
    refute Task.yield(seater, 300), "the seat was written while the denial held the estate"

    send(denier.pid, :go)
    assert {:ok, change} = Task.await(denier, 25_000)
    assert group_id in change.archived_athanor_ids

    assert {:error, :athanor_archived} = Task.await(seater, 25_000)

    unboxed(fn ->
      refute Arca.Repo.exists?(where(Membership, user_id: ^other))
      assert Arca.Repo.get(Athanor, group_id).status == "archived"
    end)
  end
end
