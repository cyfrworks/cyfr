# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MemberFreezeRaceTest do
  @moduledoc """
  The membership freeze is decided in the adding transaction: an add that
  passed every check before it and then waits on its person's lock reads
  the group again under the athanor's lock once it proceeds, so a member
  whose recovery is still open, seated meanwhile, freezes the group for
  it. PostgreSQL alone shows the lock wait the case synchronizes on.
  """

  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, RestorePerson, User}

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  @tag :postgres
  @tag timeout: 60_000
  test "a member add waiting on its person rechecks a group that became frozen meanwhile" do
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
                 Arca.Users.mint(
                   Prima.Actor.system(),
                   %{
                     id: id,
                     provider: "github",
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
            from(u in User, where: u.id == ^carol)
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

    adding =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:add_backend, backend})

          Sanctum.Providers.Member.handle(ctx, %{
            "action" => "add",
            "athanor" => athanor_id,
            "user_id" => carol
          })
        end)
      end)

    on_exit(fn -> stop(adding.pid) end)
    assert_receive {:add_backend, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend, ["users", "FOR UPDATE"])

    assert {:ok, %{state: "added"}} =
             unboxed(fn ->
               Sanctum.Providers.Member.handle(ctx, %{
                 "action" => "add",
                 "athanor" => athanor_id,
                 "user_id" => bob
               })
             end)

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

    assert {:error, _} = result
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
