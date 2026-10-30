# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharesTest do
  use ExUnit.Case, async: false

  import Arca.Test.Shares
  import Ecto.Query

  alias Arca.Shares
  alias Arca.Test.QueryCounter

  @incomplete ~s({"hosts":["api.example.com"],"scheme":"https"})

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    terry = owner!()
    {:ok, terry: terry, entry: entry!(terry.actor)}
  end

  defp administrator!(user_id) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.Membership, [
        %{
          id: Prima.UUID7.generate_id("mem"),
          user_id: user_id,
          scope: "platform",
          status: "active",
          added_by: "test",
          created_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp offered_ids(user_id) do
    {:ok, offered} = Shares.offered_to(%Prima.Actor{user_id: user_id}, [])
    Enum.map(offered, & &1.share.id)
  end

  defp leave!(athanor_id, user_id) do
    {:ok, _} =
      Arca.SecurityTransitions.leave_athanor(Prima.Actor.in_athanor(athanor_id), user_id,
        verify: fn _ -> :ok end
      )

    :ok
  end

  describe "create/3" do
    test "a share reads back with its entry, audience and caps, and no material or name",
         %{terry: terry, entry: entry} do
      assert {:ok, share} =
               Shares.create(terry.actor, %{
                 entry_id: entry.id,
                 audience: "everyone",
                 person_daily: 5
               })

      assert "shr_" <> _ = share.id

      assert Map.take(share, [
               :athanor_id,
               :vault_entry_id,
               :audience,
               :group_id,
               :person_daily,
               :total_daily,
               :status,
               :created_by
             ]) == %{
               athanor_id: terry.athanor.id,
               vault_entry_id: entry.id,
               audience: "everyone",
               group_id: nil,
               person_daily: 5,
               total_daily: nil,
               status: "active",
               created_by: terry.user.id
             }

      assert Enum.sort(Map.keys(share)) ==
               Enum.sort(~w(id athanor_id vault_entry_id audience group_id person_daily
                            total_daily status created_by inserted_at updated_at)a)

      assert {:ok, [^share]} = Shares.list(terry.actor)
      assert {:ok, ^share} = Shares.get(terry.actor, share.id)
    end

    test "a group audience names a group its creator is an active member of",
         %{terry: terry, entry: entry} do
      traders = group!([terry.user.id])

      assert {:ok, %{audience: "group", group_id: group_id}} =
               Shares.create(terry.actor, %{
                 entry_id: entry.id,
                 audience: "group",
                 group_id: traders.id
               })

      assert group_id == traders.id
    end

    test "every refusal writes nothing", %{terry: terry, entry: entry} do
      stranger = owner!()
      outsiders = group!([stranger.user.id])
      archived = group!([terry.user.id])

      {:ok, _} =
        Arca.SecurityTransitions.archive_athanor(Prima.Actor.system(), archived.id,
          verify: fn _ -> :ok end
        )

      disclosed = entry!(terry.actor, %{attach_only: false})
      oauth = entry!(terry.actor, %{kind: "oauth"})
      incomplete = entry!(terry.actor, %{destination: @incomplete})
      revoked = entry!(terry.actor)
      :ok = Arca.VaultStorage.set_status(terry.actor, revoked.id, "revoked")
      theirs = entry!(stranger.actor)
      group_actor = %Prima.Actor{athanor_id: outsiders.id, user_id: stranger.user.id}
      not_owner = %{terry.actor | user_id: stranger.user.id}

      for {actor, attrs, refusal} <- [
            {group_actor, %{entry_id: entry.id}, :not_own_athanor},
            {not_owner, %{entry_id: entry.id}, :not_own_athanor},
            {terry.actor, %{entry_id: entry.id, audience: "group", group_id: outsiders.id},
             :not_member},
            {terry.actor, %{entry_id: entry.id, audience: "group", group_id: archived.id},
             :not_member},
            {terry.actor, %{entry_id: disclosed.id}, :disclosed_not_shareable},
            {terry.actor, %{entry_id: oauth.id}, :kind_not_shareable},
            {terry.actor, %{entry_id: incomplete.id}, :destination_incomplete},
            {terry.actor, %{entry_id: revoked.id}, {:entry_unavailable, "revoked"}},
            {terry.actor, %{entry_id: theirs.id}, :not_found}
          ] do
        assert {:error, ^refusal} =
                 Shares.create(actor, Map.merge(%{audience: "everyone"}, attrs)),
               inspect(refusal)
      end

      assert {:ok, []} = Shares.list(terry.actor)
      assert {:ok, []} = Shares.list(stranger.actor)
    end

    test "a denied creator shares nothing", %{terry: terry, entry: entry} do
      {1, _} =
        Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^terry.user.id),
          set: [status: "denied"]
        )

      assert {:error, :not_own_athanor} =
               Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"})
    end

    test "a row outside the share's rules is refused before any query",
         %{terry: terry, entry: entry} do
      for attrs <- [
            %{audience: "group"},
            %{audience: "group", group_id: ""},
            %{audience: "everyone", group_id: "ath_x"},
            %{audience: "listed"},
            %{audience: "everyone", person_daily: -1},
            %{audience: "everyone", total_daily: Arca.Schemas.Share.max_cap() + 1}
          ] do
        QueryCounter.assert_queries(0, fn ->
          assert {:error, {:invalid, _}} =
                   Shares.create(terry.actor, Map.put(attrs, :entry_id, entry.id)),
                 inspect(attrs)
        end)
      end
    end

    test "a second active share of one entry to one audience is refused, everyone included",
         %{terry: terry, entry: entry} do
      traders = group!([terry.user.id])
      pair = group!([terry.user.id])
      everyone = share!(terry.actor, entry.id)
      group = share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})

      assert {:error, :already_shared} =
               Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"})

      assert {:error, :already_shared} =
               Shares.create(terry.actor, %{
                 entry_id: entry.id,
                 audience: "group",
                 group_id: traders.id
               })

      # Another group is another audience, and a revoked share is no
      # longer the key's holder.
      assert {:ok, _} =
               Shares.create(terry.actor, %{
                 entry_id: entry.id,
                 audience: "group",
                 group_id: pair.id
               })

      assert {:ok, _} = Shares.revoke(terry.actor, everyone.id, "needs_consent")

      assert {:ok, again} =
               Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"})

      assert again.id != everyone.id
      assert share_status(terry.actor, group.id) == "active"
    end

    test "the caller's check runs under the locks and its refusal writes nothing",
         %{terry: terry, entry: entry} do
      assert {:error, :unconfirmed} =
               Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"},
                 verify: fn -> {:error, :unconfirmed} end
               )

      assert {:ok, []} = Shares.list(terry.actor)
    end
  end

  describe "the owner's actor" do
    test "an actor with no athanor or no person is refused before any query",
         %{entry: entry} do
      QueryCounter.assert_queries(0, fn ->
        assert {:error, :no_athanor} = Shares.create(%Prima.Actor{}, %{entry_id: entry.id})

        assert {:error, :no_person} =
                 Shares.create(Prima.Actor.in_athanor("ath_x"), %{entry_id: entry.id})

        assert {:error, :no_athanor} = Shares.list(%Prima.Actor{})
        assert {:error, :no_athanor} = Shares.get(%Prima.Actor{}, "shr_x")
        assert {:error, :no_athanor} = Shares.revoke(%Prima.Actor{}, "shr_x", "needs_consent")
        assert {:error, :no_athanor} = Shares.set_caps(%Prima.Actor{}, "shr_x", nil, nil)
        assert {:error, :no_person} = Shares.offered_to(%Prima.Actor{}, [])

        assert {:error, :cross_tenant} =
                 Shares.head_profiles_referencing_share(Prima.Actor.in_athanor("ath_x"), "shr_x")

        assert {:error, :cross_tenant} = Shares.revoke_all(Prima.Actor.in_athanor("ath_x"))
      end)
    end

    test "another athanor's share is not found by its id", %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)
      other = owner!()

      assert {:error, :not_found} = Shares.get(other.actor, share.id)
      assert {:error, :not_found} = Shares.revoke(other.actor, share.id, "needs_consent")
      assert {:error, :not_found} = Shares.set_caps(other.actor, share.id, 1, 1)

      assert {:error, :not_found} =
               Shares.set_audience(
                 other.actor,
                 share.id,
                 %{audience: "everyone", group_id: nil},
                 %{audience: "everyone", group_id: nil}
               )

      assert share_status(terry.actor, share.id) == "active"
    end
  end

  describe "set_audience/4" do
    test "moves the audience the caller saw, and refuses one it did not",
         %{terry: terry, entry: entry} do
      traders = group!([terry.user.id])
      share = share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})
      seen = %{audience: "group", group_id: traders.id}
      everyone = %{audience: "everyone", group_id: nil}

      assert {:ok, %{audience: "everyone", group_id: nil}} =
               Shares.set_audience(terry.actor, share.id, seen, everyone)

      # The caller's read is stale now.
      assert {:error, :conflict} = Shares.set_audience(terry.actor, share.id, seen, everyone)
      assert {:ok, %{audience: "everyone"}} = Shares.get(terry.actor, share.id)
    end

    test "a group its creator does not sit in, an audience another share holds, and a revoked " <>
           "share are refused",
         %{terry: terry, entry: entry} do
      outsiders = group!([owner!().user.id])
      traders = group!([terry.user.id])
      everyone = %{audience: "everyone", group_id: nil}
      to_traders = %{audience: "group", group_id: traders.id}
      _held = share!(terry.actor, entry.id)
      share = share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})

      assert {:error, :not_member} =
               Shares.set_audience(terry.actor, share.id, to_traders, %{
                 audience: "group",
                 group_id: outsiders.id
               })

      assert {:error, :already_shared} =
               Shares.set_audience(terry.actor, share.id, to_traders, everyone)

      assert {:ok, _} = Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:error, {:share_unavailable, "revoked"}} =
               Shares.set_audience(terry.actor, share.id, to_traders, to_traders)

      assert {:error, {:invalid, _}} =
               Shares.set_audience(terry.actor, share.id, to_traders, %{
                 audience: "group",
                 group_id: nil
               })
    end
  end

  describe "set_caps/4" do
    test "sets nil for no limit, 0 for no use and N, and refuses anything else",
         %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)

      for {person, total} <- [{0, nil}, {nil, 7}, {nil, nil}, {Arca.Schemas.Share.max_cap(), 0}] do
        assert {:ok, %{person_daily: ^person, total_daily: ^total}} =
                 Shares.set_caps(terry.actor, share.id, person, total)
      end

      for {person, total} <- [{-1, nil}, {nil, Arca.Schemas.Share.max_cap() + 1}, {"1", nil}] do
        assert {:error, {:invalid, _}} = Shares.set_caps(terry.actor, share.id, person, total)
      end

      assert {:ok, _} = Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:error, {:share_unavailable, "revoked"}} =
               Shares.set_caps(terry.actor, share.id, 1, 1)
    end
  end

  describe "revoke/3" do
    test "revokes the share and blocks its dependents in another athanor, in one transaction",
         %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)
      alice = owner!()
      bob = owner!()
      profile = bound!(alice.athanor.id, share.id)
      revoked = bound!(bob.athanor.id, share.id)

      :ok =
        Arca.ProfileStorage.transition(
          Prima.Actor.in_athanor(bob.athanor.id),
          revoked.id,
          ["active"],
          "revoked"
        )

      assert {:ok, %{share_ids: [share_id], blocked: blocked}} =
               Shares.revoke(terry.actor, share.id, "needs_consent")

      assert share_id == share.id
      assert blocked == [{alice.athanor.id, profile.id}]
      assert share_status(terry.actor, share.id) == "revoked"
      assert profile_status(alice.athanor.id, profile.id) == "needs_consent"
      assert profile_status(bob.athanor.id, revoked.id) == "revoked"

      # A retry finishes what an earlier attempt left; the row stays.
      assert {:ok, %{share_ids: [^share_id]}} =
               Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:ok, [%{id: ^share_id, status: "revoked"}]} = Shares.list(terry.actor)
    end

    test "a block that may not land rolls the revocation back", %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)
      alice = owner!()
      bound!(alice.athanor.id, share.id)

      assert {:error, _} = Shares.revoke(terry.actor, share.id, "active")
      assert share_status(terry.actor, share.id) == "active"
    end
  end

  describe "offered_to/2" do
    test "everyone is every active person but the owner; a group is its active members",
         %{terry: terry, entry: entry} do
      alice = owner!()
      bob = owner!()
      traders = group!([terry.user.id, alice.user.id])
      to_everyone = share!(terry.actor, entry.id)
      to_traders = share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})

      assert offered_ids(alice.user.id) == [to_traders.id, to_everyone.id]
      assert offered_ids(bob.user.id) == [to_everyone.id]
      assert offered_ids(terry.user.id) == []

      {:ok, [offer | _]} = Shares.offered_to(alice.actor, [])
      assert offer.owner_user_id == terry.user.id
      assert offer.source.id == entry.id
      assert offer.source.destination == destination()
      refute Map.has_key?(offer.source, :sealed_payload)
      refute Map.has_key?(offer.source, :name)

      assert {:ok, []} = Shares.offered_to(alice.actor, provider_hint: "other.example")
    end

    test "a person who left the group, an archived group, a denied person and a revoked share " <>
           "are offered nothing",
         %{terry: terry, entry: entry} do
      alice = owner!()
      bob = owner!()
      traders = group!([terry.user.id, alice.user.id, bob.user.id])
      share = share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})

      assert share.id in offered_ids(alice.user.id)
      :ok = leave!(traders.id, alice.user.id)
      assert offered_ids(alice.user.id) == []
      assert {:ok, false} = Shares.member?(alice.actor, traders.id, alice.user.id)
      assert {:ok, true} = Shares.member?(bob.actor, traders.id, bob.user.id)

      {1, _} =
        Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^bob.user.id),
          set: [status: "denied"]
        )

      assert offered_ids(bob.user.id) == []
      assert {:ok, false} = Shares.member?(bob.actor, traders.id, bob.user.id)

      carol = owner!()
      to_everyone = share!(terry.actor, entry.id)
      assert offered_ids(carol.user.id) == [to_everyone.id]
      {:ok, _} = Shares.revoke(terry.actor, to_everyone.id, "needs_consent")
      assert offered_ids(carol.user.id) == []
    end

    test "an entry no longer active is offered through none of its shares",
         %{terry: terry, entry: entry} do
      alice = owner!()
      share!(terry.actor, entry.id)
      :ok = Arca.VaultStorage.set_status(terry.actor, entry.id, "needs_reauth")
      assert offered_ids(alice.user.id) == []
    end

    test "member? is the person's own question or the platform's", %{terry: terry} do
      traders = group!([terry.user.id])
      assert {:ok, true} = Shares.member?(Prima.Actor.system(), traders.id, terry.user.id)

      assert {:error, :cross_tenant} =
               Shares.member?(%Prima.Actor{user_id: "usr_other"}, traders.id, terry.user.id)
    end
  end

  describe "get_for_source/2" do
    test "answers the share whatever its status, with its source and owner",
         %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)
      {:ok, _} = Shares.revoke(terry.actor, share.id, "needs_consent")

      assert {:ok, %{share: %{id: id, status: "revoked"}, source: source, owner_user_id: owner}} =
               Shares.get_for_source(owner!().actor, share.id)

      assert id == share.id
      assert owner == terry.user.id
      assert source.binding_digest == entry.binding_digest
      assert {:error, :not_found} = Shares.get_for_source(Prima.Actor.system(), "shr_none")
    end
  end

  describe "administrator_shares/1" do
    test "the active shares to everyone of an active administrator, newest first",
         %{terry: terry, entry: entry} do
      admin = owner!()
      :ok = administrator!(admin.user.id)
      first = share!(admin.actor, entry!(admin.actor).id)
      second = share!(admin.actor, entry!(admin.actor).id)
      revoked = share!(admin.actor, entry!(admin.actor).id)
      {:ok, _} = Shares.revoke(admin.actor, revoked.id, "needs_consent")
      staff = group!([admin.user.id])

      _to_staff =
        share!(admin.actor, entry!(admin.actor).id, %{audience: "group", group_id: staff.id})

      # A member's share to everyone is never a newcomer's candidate.
      _members = share!(terry.actor, entry.id)

      {:ok, candidates} = Shares.administrator_shares(Prima.Actor.system())
      assert Enum.map(candidates, & &1.share.id) == [second.id, first.id]
      assert Enum.all?(candidates, &(&1.owner_user_id == admin.user.id))
    end
  end

  describe "head_profiles_referencing_share/2" do
    test "the heads binding the share in every athanor, platform scope only",
         %{terry: terry, entry: entry} do
      share = share!(terry.actor, entry.id)
      alice = owner!()
      bob = owner!()
      a = bound!(alice.athanor.id, share.id)
      b = bound!(bob.athanor.id, share.id)

      assert {:ok, pairs} =
               Shares.head_profiles_referencing_share(Prima.Actor.system(), share.id)

      assert pairs == Enum.sort([{alice.athanor.id, a.id}, {bob.athanor.id, b.id}])
    end
  end
end

defmodule Arca.SharesConcurrencyTest do
  @moduledoc """
  A share's writers on connections of their own: inside the sandbox one
  shared connection would serialize the writers the cases are about. On
  PostgreSQL the waiting writer is seen waiting on its row lock; on
  SQLite the transaction holding the write lock is what it waits for.
  Every row a case writes is removed when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Test.Shares, as: Fixture
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    {:ok, made} = Agent.start(fn -> [] end)

    on_exit(fn ->
      unboxed(fn -> purge!(Agent.get(made, & &1)) end)
      Agent.stop(made)
    end)

    {:ok, made: made}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # A person and their own athanor, recorded for the purge.
  defp owned!(made) do
    owner = unboxed(&Fixture.owner!/0)
    :ok = Agent.update(made, &[owner | &1])
    owner
  end

  defp purge!(made) do
    for %{athanor: athanor, user: user} <- made do
      {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(athanor.id))
      Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id))

      Arca.Repo.delete_all(from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id))

      Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user.id))
    end
  end

  # Run `write` in a transaction of its own and hold it open, once
  # `write` has run, until the case lets it go.
  defp holding(write) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            result = write.()
            send(parent, {:held, self(), result})

            receive do
              :go -> result
            end
          end)
        end)
      end)

    assert_receive {:held, holder, result}, 10_000
    {task, holder, result}
  end

  # Start `write` on its own connection and answer once it is seen
  # waiting: on PostgreSQL on a lock in a statement naming `fragments`, on
  # SQLite still unanswered while the holder holds the write lock.
  defp waiting(write, fragments) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          if Arca.Test.Adapter.postgres?() do
            %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, pid})
          end

          write.()
        end)
      end)

    if Arca.Test.Adapter.postgres?() do
      assert_receive {:backend, pid}, 10_000
      :ok = Arca.Test.LockWait.await_lock_wait!(pid, fragments)
    else
      assert Task.yield(task, 300) == nil
    end

    task
  end

  defp release({task, holder, _result}) do
    send(holder, :go)
    Task.await(task, 15_000)
  end

  test "a share created while a rebind holds the entry waits, then sees the moved entry", %{
    made: made
  } do
    terry = owned!(made)
    entry = unboxed(fn -> Fixture.entry!(terry.actor) end)

    held =
      holding(fn ->
        Arca.VaultStorage.move_binding(
          terry.actor,
          entry.id,
          "sha256:d0",
          %{attach_only: false, binding_digest: "sha256:d1"},
          "needs_consent"
        )
      end)

    assert {_task, _holder, {:ok, []}} = held

    create =
      waiting(
        fn -> Arca.Shares.create(terry.actor, %{entry_id: entry.id, audience: "everyone"}) end,
        ["vault_entries", "FOR UPDATE"]
      )

    assert {:ok, {:ok, []}} = release(held)
    assert Task.await(create, 15_000) == {:error, :disclosed_not_shareable}
    assert unboxed(fn -> Arca.Shares.list(terry.actor) end) == {:ok, []}
  end

  test "a claim holding the share delays its revoke, which then lands", %{made: made} do
    terry = owned!(made)

    share =
      unboxed(fn -> Fixture.share!(terry.actor, Fixture.entry!(terry.actor).id) end)

    held = holding(fn -> Arca.ShareUsage.claim(terry.actor, share.id, "usr_alice") end)

    revoke =
      waiting(
        fn -> Arca.Shares.revoke(terry.actor, share.id, "needs_consent") end,
        ["shares", "FOR UPDATE"]
      )

    assert {:ok, {:ok, %{person: 1}}} = release(held)
    assert {:ok, %{share_ids: [id]}} = Task.await(revoke, 15_000)
    assert id == share.id

    assert {:ok, %{people: [%{count: 1}]}} =
             unboxed(fn -> Arca.ShareUsage.usage(terry.actor, share.id, 1) end)
  end

  test "a revoke holding the share delays a claim, which then counts nothing", %{made: made} do
    terry = owned!(made)

    share =
      unboxed(fn -> Fixture.share!(terry.actor, Fixture.entry!(terry.actor).id) end)

    held = holding(fn -> Arca.Shares.revoke(terry.actor, share.id, "needs_consent") end)

    claim =
      waiting(
        fn -> Arca.ShareUsage.claim(terry.actor, share.id, "usr_alice") end,
        ["shares", "FOR SHARE"]
      )

    assert {:ok, {:ok, %{share_ids: [_]}}} = release(held)
    assert Task.await(claim, 15_000) == {:error, {:share_unavailable, "revoked"}}

    assert {:ok, %{people: [], totals: []}} =
             unboxed(fn -> Arca.ShareUsage.usage(terry.actor, share.id, 1) end)
  end

  test "a revision binding a share while its revoke runs: one order or the other", %{made: made} do
    terry = owned!(made)
    alice = owned!(made)

    for round <- 1..5 do
      share =
        unboxed(fn -> Fixture.share!(terry.actor, Fixture.entry!(terry.actor).id) end)

      profile =
        unboxed(fn ->
          {:ok, profile} =
            Arca.Test.Writers.put_profile(%{
              athanor_id: alice.athanor.id,
              source_ref: "formula:local.race-#{round}",
              kind: "owner",
              label: "default",
              status: "active"
            })

          profile
        end)

      commit =
        Task.async(fn ->
          unboxed(fn ->
            Arca.ConsentStorage.insert_revision(
              Fixture.revision_attrs(alice.athanor.id, profile.id, 1),
              [Fixture.share_ref(share.id)],
              nil
            )
          end)
        end)

      revoke =
        Task.async(fn ->
          unboxed(fn -> Arca.Shares.revoke(terry.actor, share.id, "needs_consent") end)
        end)

      committed = Task.await(commit, 30_000)
      {:ok, %{blocked: blocked}} = Task.await(revoke, 30_000)
      status = unboxed(fn -> Fixture.profile_status(alice.athanor.id, profile.id) end)

      case committed do
        {:ok, _consent} ->
          assert {alice.athanor.id, profile.id} in blocked
          assert status == "needs_consent"

        {:error, {:share_unavailable, "revoked"}} ->
          assert blocked == []
          assert status == "active"
      end
    end
  end
end
