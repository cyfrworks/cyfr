# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.InvitationFreezeRaceTest do
  @moduledoc """
  A declared restore's hold on a shared thread decides an invitation's
  acceptance as it decides an add: an activation by person identifier
  locks the invitations' threads after the person, in the order a seat
  takes them, before it reads the hold, so a member whose recovery is
  still open, seated by an add still uncommitted, holds the thread for the
  activation that waited on it. PostgreSQL alone shows the lock waits the
  case synchronizes on.
  """

  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox

  alias Arca.Schemas.{
    ExternalIdentity,
    RestorePerson,
    SharedThread,
    SharedThreadMember,
    User
  }

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  @tag :postgres
  @tag timeout: 60_000
  test "identifier invitation cannot activate after its thread freezes while its UPDATE waits" do
    run_race()
  end

  # Whether a declared restore holds the thread: one of its people still
  # recovers.
  defp frozen?(thread_id) do
    unboxed(fn ->
      Arca.Repo.exists?(
        where(Arca.SecurityTransitions.frozen_shared_threads(), [m], m.thread_id == ^thread_id)
      )
    end)
  end

  defp run_race do
    ids = for _ <- 1..3, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
    [alice, bob, carol] = ids
    restore_id = Prima.UUID7.generate_id("rst")
    parent = self()

    on_exit(fn ->
      unboxed(fn ->
        threads =
          Arca.Repo.all(from(t in SharedThread, where: t.created_by in ^ids, select: t.id))

        Arca.Repo.delete_all(from(r in RestorePerson, where: r.user_id in ^ids))

        Arca.Repo.delete_all(
          from(m in SharedThreadMember, where: m.user_id in ^ids or m.thread_id in ^threads)
        )

        Arca.Repo.delete_all(from(t in SharedThread, where: t.id in ^threads))
        Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^ids))
        Arca.Repo.delete_all(from(u in User, where: u.id in ^ids))
      end)
    end)

    thread_id =
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

        assert {:ok, thread} = Sanctum.SharedThreads.create(alice, "Freeze race")
        Arca.Repo.insert!(%RestorePerson{restore_id: restore_id, user_id: bob, open: true})
        thread.id
      end)

    identifier = "per_" <> Prima.Digest.sha256_hex(carol)

    invitation_id =
      unboxed(fn ->
        assert {:ok, invitation} =
                 Arca.SharedThreadMembers.invite(
                   Prima.Actor.system(),
                   thread_id,
                   identifier,
                   alice
                 )

        invitation.id
      end)

    refute frozen?(thread_id)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(m in SharedThreadMember, where: m.id == ^invitation_id)
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
            assert {:ok, :added} =
                     Sanctum.SharedThreads.add(alice, thread_id, user_id: bob)

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
          Arca.SharedThreadMembers.activate(Prima.Actor.system(), carol, identifier)
        end)
      end)

    on_exit(fn -> stop(adding.pid) end)
    assert_receive {:add_backend, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend)

    # The activation waits for Bob's lock on the thread before it reads
    # the hold; one that read the hold first would wait on Carol's
    # invitation row instead. Either wait is observed here, and the
    # outcome below tells them apart.
    %{rows: [[waiting_query]]} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [backend])
      end)

    assert (String.contains?(waiting_query, "UPDATE") and
              String.contains?(waiting_query, "shared_thread_members")) or
             (String.contains?(waiting_query, "SELECT") and
                String.contains?(waiting_query, "shared_threads"))

    send(bob_add.pid, :commit)
    assert {:ok, :ok} = Task.await(bob_add, 5_000)

    assert frozen?(thread_id)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    result = Task.await(adding, 5_000)

    seated =
      unboxed(fn ->
        Arca.Repo.exists?(
          from(m in SharedThreadMember,
            where: m.thread_id == ^thread_id and m.user_id == ^carol and m.status == "active"
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
