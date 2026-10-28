# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InvitationFreezeRaceTest do
  @moduledoc """
  The membership freeze holds at an invitation's acceptance as at an
  add: an activation by person identifier locks the invitations'
  athanors after the person, in the order a seat takes them,
  before it reads the freeze, so a member whose recovery is still open,
  seated by an add still uncommitted, freezes the group for the
  activation that waited on it. PostgreSQL alone shows the lock waits the
  cases synchronize on.
  """

  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, RestorePerson, User}

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  @tag :postgres
  @tag timeout: 60_000
  test "identifier invitation cannot activate after its group freezes while its UPDATE waits" do
    run_race()
  end

  defp run_race do
    ids = for _ <- 1..3, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
    [alice, bob, carol] = ids
    athanor_id = Prima.UUID7.generate_id("ath")
    restore_id = Prima.UUID7.generate_id("rst")
    parent = self()

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(r in RestorePerson, where: r.user_id in ^ids))

        Arca.Repo.delete_all(
          from(m in Membership, where: m.user_id in ^ids or m.athanor_id == ^athanor_id)
        )

        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor_id))
        Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^ids))
        Arca.Repo.delete_all(from(u in User, where: u.id in ^ids))
      end)
    end)

    unboxed(fn ->
      now = DateTime.utc_now()

      for id <- ids do
        subject = "freeze-race-" <> id

        assert {:ok, _} =
                 Arca.Test.People.mint(
                   Prima.Actor.system(),
                   %{
                     id: id,
                     first_seen_at: now,
                     last_seen_at: now,
                     created_at: now,
                     updated_at: now
                   },
                   %{
                     key: "github|https://github.com|" <> subject,
                     provider: "github",
                     issuer: "https://github.com",
                     subject: subject,
                     first_seen_at: now,
                     last_seen_at: now
                   }
                 )
      end

      assert {:ok, _} =
               Arca.Athanors.insert(Prima.Actor.system(), %{
                 id: athanor_id,
                 kind: "group",
                 name: "Freeze race",
                 slug: "freeze-race-#{System.unique_integer([:positive])}",
                 created_by: alice
               })

      assert {:ok, _} =
               Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{
                 user_id: alice,
                 scope: "athanor",
                 added_by: alice
               })

      Arca.Repo.insert!(%RestorePerson{restore_id: restore_id, user_id: bob, open: true})
    end)

    identifier = "per_" <> Prima.Digest.sha256_hex(carol)

    invitation_id =
      unboxed(fn ->
        attrs = %{
          scope: "athanor",
          status: "invited",
          added_by: alice,
          person_identifier: identifier
        }

        assert {:ok, invitation} = Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), attrs)
        invitation.id
      end)

    ctx =
      Sanctum.Context.build(
        user_id: alice,
        athanor_id: athanor_id,
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    actor = Prima.Actor.in_athanor(athanor_id)
    assert {:ok, false} = unboxed(fn -> Arca.SecurityTransitions.restore_frozen?(actor) end)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(m in Membership, where: m.id == ^invitation_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(parent, :holds_carol)

            receive do
              :release -> :ok
            after
              30_000 -> Arca.Repo.rollback(:holder_timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> stop(holder.pid) end)
    assert_receive :holds_carol, 5_000

    bob_add =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            assert {:ok, %{state: "added"}} =
                     Sanctum.Providers.Member.handle(ctx, %{
                       "action" => "add",
                       "athanor" => athanor_id,
                       "user_id" => bob
                     })

            send(parent, :bob_added_uncommitted)

            receive do
              :commit -> :ok
            after
              30_000 -> Arca.Repo.rollback(:bob_timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> stop(bob_add.pid) end)
    assert_receive :bob_added_uncommitted, 5_000

    adding =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:add_backend, backend})

          Arca.Members.activate_invited_identifier(
            Prima.Actor.system(),
            carol,
            identifier,
            DateTime.utc_now()
          )
        end)
      end)

    on_exit(fn -> stop(adding.pid) end)
    assert_receive {:add_backend, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend)

    # The activation waits for Bob's athanor lock before it reads the
    # freeze; one that read the freeze first would wait on Carol's
    # invitation row instead. Either wait is observed here, and the
    # outcome below tells them apart.
    %{rows: [[waiting_query]]} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [backend])
      end)

    assert (String.contains?(waiting_query, "UPDATE") and
              String.contains?(waiting_query, "memberships")) or
             (String.contains?(waiting_query, "SELECT") and
                String.contains?(waiting_query, "athanors"))

    send(bob_add.pid, :commit)
    assert {:ok, :ok} = Task.await(bob_add, 5_000)

    assert {:ok, true} = unboxed(fn -> Arca.SecurityTransitions.restore_frozen?(actor) end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    result = Task.await(adding, 5_000)

    seated =
      unboxed(fn ->
        Arca.Repo.exists?(
          from(m in Membership,
            where: m.athanor_id == ^athanor_id and m.user_id == ^carol and m.status == "active"
          )
        )
      end)

    assert {:ok, []} = result
    refute seated
  end

  defp stop(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        5_000 -> flunk("probe process did not stop")
      end
    end
  end
end
