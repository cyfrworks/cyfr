# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DoorAdminsRaceTest do
  @moduledoc """
  A removal of a door entry that starts while another change of that
  entry is still open, each on a connection of its own outside the
  sandbox. The removal reads the entry, and the mark of the person it
  names, inside its own transaction once the other change committed, so
  it decides on what that change wrote, never on what stood before it:
  an entry that became a marked person's allow is refused, and a request
  that was approved meanwhile is not rejected. On PostgreSQL the removal
  is seen waiting on a lock the other change holds; on SQLite on the
  write lock it holds. Every row the case writes is removed when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2, where: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, Doors}
  alias Arca.Schemas.{CellLease, PersonIdentity, ServerAllowlistEntry, User}
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Door.Store

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    hold_slot!()
    {:ok, admin: person!(true), person: person!(false)}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the process-wide standing and the claim switch are
  # restored after the case, and the lease row is removed.
  defp hold_slot! do
    for key <- [:standing, :generation, :slot],
        do: Prima.Test.Env.erase_persistent_term({ControlPlane, key})

    Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)
    end)

    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end

  # A person of this CYFR, committed, with their account's identifier,
  # marked an administrator when `admin?`. Their rows and every door entry
  # naming them are removed after the case.
  defp person!(admin?) do
    n = System.unique_integer([:positive])
    user_id = "usr_doorrace#{n}"
    identifier = "per_" <> Prima.Digest.sha256_hex("door-race-#{n}")
    now = DateTime.utc_now()

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(ServerAllowlistEntry, value: ^identifier))
        Arca.Repo.delete_all(where(PersonIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
      end)
    end)

    unboxed(fn ->
      {1, _} =
        Arca.Repo.insert_all(User, [
          %{
            id: user_id,
            admission: "remote",
            status: "active",
            platform_admin_at: if(admin?, do: now),
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          }
        ])

      {1, _} =
        Arca.Repo.insert_all(PersonIdentity, [
          %{
            id: "pid_doorrace#{n}",
            user_id: user_id,
            identifier: identifier,
            head_hash: "sha256:" <> Prima.Digest.sha256_hex("head-#{n}"),
            directory_url: "https://dir.example",
            inserted_at: now,
            updated_at: now
          }
        ])
    end)

    %{user_id: user_id, identifier: identifier}
  end

  # The other change: `change` runs in one transaction that holds its locks
  # until the test lets it commit.
  defp holding(test, change) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            answer = change.()
            send(test, {:holds, self()})
            receive do: (:commit -> answer)
          end)
        end)
      end)

    assert_receive {:holds, holder}, 5_000
    {task, holder}
  end

  # The removal, on a connection of its own, seen waiting for the holder.
  defp waiting(test, removal) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          if postgres?() do
            %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
            send(test, {:backend, pid})
          end

          removal.()
        end)
      end)

    if postgres?() do
      assert_receive {:backend, pid}, 5_000
      :ok = LockWait.await_lock_wait!(pid)
    end

    refute Task.yield(task, 300), "the removal decided while the other change held its locks"
    task
  end

  defp entries(identifier) do
    unboxed(fn ->
      Arca.Repo.all(
        from(e in ServerAllowlistEntry,
          where: e.kind == "identifier" and e.value == ^identifier,
          select: {e.effect, e.status}
        )
      )
    end)
  end

  defp marked?(person),
    do: unboxed(fn -> Arca.Repo.get!(User, person.user_id).platform_admin_at end) != nil

  test "a removal that started on a deny, while the entry became a marked person's allow, is refused",
       %{admin: admin, person: person} do
    {:ok, deny} =
      unboxed(fn -> Store.deny("identifier", person.identifier, admin.user_id) end)

    test = self()

    # The deny turned into an allow, then the person marked: what the
    # door's allow and a marking write, in one transaction left open.
    {marking, holder} =
      holding(test, fn ->
        Arca.Users.set_platform_admin(server(), person.user_id, true,
          by: admin.user_id,
          also: fn _user ->
            case Doors.update(server(), deny.id, %{effect: "allow", added_by: admin.user_id}) do
              {:ok, _entry} -> :ok
              {:error, _} = refused -> refused
            end
          end
        )
      end)

    removal = waiting(test, fn -> Store.remove(deny.id) end)

    send(holder, :commit)
    assert {:ok, {:ok, %{platform_admin_at: %DateTime{}}}} = Task.await(marking, 25_000)
    assert Task.await(removal, 25_000) == {:error, :platform_admin}
    assert entries(person.identifier) == [{"allow", "allowed"}]
    assert marked?(person)
  end

  test "a rejection that started on a request, while the request was approved, removes nothing",
       %{admin: admin, person: person} do
    {:ok, :created, request} =
      unboxed(fn -> Store.request("identifier", person.identifier, admin.user_id) end)

    test = self()

    {approval, holder} =
      holding(test, fn ->
        Doors.update(server(), request.id, %{status: "allowed", added_by: admin.user_id})
      end)

    rejection = waiting(test, fn -> Store.resolve(request.id, :reject, admin.user_id) end)

    send(holder, :commit)
    assert {:ok, {:ok, %{status: "allowed"}}} = Task.await(approval, 25_000)
    assert Task.await(rejection, 25_000) == {:error, :not_a_request}
    assert entries(person.identifier) == [{"allow", "allowed"}]
  end
end
