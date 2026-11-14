# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsersMarkingRaceTest do
  @moduledoc """
  A person made an administrator while the door removes their allow or
  denies them, on real connections outside the sandbox, in either order.
  The door's change reads the mark with the person's row locked
  (`Arca.Users.unless_admin/3`), the row a marking writes, so whichever
  starts second waits for the first to commit and decides on what it
  wrote: a marking that committed first is seen and the removal or deny is
  refused; a removal that committed first is written over by the marking's
  allow; a deny that committed first refuses the marking's allow, and the
  marking rolls back. On PostgreSQL the second waits on the person's row;
  on SQLite on the write lock the first holds.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2, where: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, Doors, Users}
  alias Arca.Schemas.{CellLease, PersonIdentity, ServerAllowlistEntry, User}
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  setup do
    hold_slot!()
    admin = person!(true)
    person = person!(false)
    {:ok, _allow} = unboxed(fn -> allow(person.identifier) end)
    {:ok, admin: admin, person: person}
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease; the process-wide standing and the claim switch are
  # restored after the case, and the lease row is removed.
  defp hold_slot! do
    for key <- [:standing, :generation, :slot],
        do: Prima.Test.Env.erase_persistent_term({Arca.ControlPlane, key})

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
    user_id = "usr_marking#{n}"
    identifier = "per_" <> Prima.Digest.sha256_hex("marking-#{n}")
    now = DateTime.utc_now()

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(ServerAllowlistEntry, value: ^identifier))
        Arca.Repo.delete_all(where(ServerAllowlistEntry, value: ^user_id))
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
            id: "pid_marking#{n}",
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

  defp allow(identifier),
    do: Doors.allow_unless_denied(server(), {"identifier", identifier}, %{added_by: "usr_ops"})

  # The marking as the administrator makes it: the mark, then the person's
  # allow, in one transaction; `hold` runs between them.
  defp mark(person, admin, hold \\ fn -> :ok end) do
    Users.set_platform_admin(server(), person.user_id, true,
      by: admin.user_id,
      also: fn _user ->
        hold.()

        case allow(person.identifier) do
          {:ok, _entry} -> :ok
          {:error, _} = refused -> refused
        end
      end
    )
  end

  # The door's removal of the person's allow and its deny of them, as
  # `Sanctum.Door.Store` writes them; `hold` runs after the mark was read.
  defp remove(person, hold \\ fn -> :ok end) do
    Users.unless_admin(server(), {"identifier", person.identifier}, fn ->
      hold.()
      {:ok, entry} = Doors.find(server(), "identifier", person.identifier)
      :ok = Doors.delete(server(), entry.id)
      {:ok, :removed}
    end)
  end

  defp deny(person, hold \\ fn -> :ok end) do
    Users.unless_admin(server(), {"identifier", person.identifier}, fn ->
      hold.()
      {:ok, entry} = Doors.find(server(), "identifier", person.identifier)
      Doors.update(server(), entry.id, %{effect: "deny", added_by: "usr_ops"})
    end)
  end

  # Holds the first change's transaction once its decision is made, until
  # the test lets it go on.
  defp holding(test) do
    fn ->
      send(test, :first_holds)
      receive do: (:go -> :ok)
    end
  end

  defp first(change) do
    task = Task.async(fn -> unboxed(change) end)
    assert_receive :first_holds, 5_000
    task
  end

  defp second(test, change, fragments) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend()})
          change.()
        end)
      end)

    assert_receive {:second, waiting}, 5_000
    if postgres?(), do: LockWait.await_lock_wait!(waiting, fragments)
    refute Task.yield(task, 300), "the second change decided while the first held its lock"
    task
  end

  defp state(person) do
    unboxed(fn ->
      {Arca.Repo.get!(User, person.user_id).platform_admin_at,
       Arca.Repo.all(
         from(e in ServerAllowlistEntry,
           where: e.kind == "identifier" and e.value == ^person.identifier,
           select: {e.effect, e.status}
         )
       )}
    end)
  end

  test "a marking that holds the person's row: the removal that waits is refused", %{
    admin: admin,
    person: person
  } do
    test = self()
    marking = first(fn -> mark(person, admin, holding(test)) end)
    removal = second(test, fn -> remove(person) end, [~s("users"), "FOR UPDATE"])

    send(marking.pid, :go)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {:error, :platform_admin} = Task.await(removal, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a removal that holds the person's row: the marking that waits writes the allow again", %{
    admin: admin,
    person: person
  } do
    test = self()
    removal = first(fn -> remove(person, holding(test)) end)
    marking = second(test, fn -> mark(person, admin) end, [~s(UPDATE "users")])

    send(removal.pid, :go)
    assert {:ok, :removed} = Task.await(removal, 25_000)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a marking that holds the person's row: the deny that waits is refused", %{
    admin: admin,
    person: person
  } do
    test = self()
    marking = first(fn -> mark(person, admin, holding(test)) end)
    denial = second(test, fn -> deny(person) end, [~s("users"), "FOR UPDATE"])

    send(marking.pid, :go)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {:error, :platform_admin} = Task.await(denial, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a deny that holds the person's row: the marking that waits is refused and writes nothing",
       %{admin: admin, person: person} do
    test = self()
    denial = first(fn -> deny(person, holding(test)) end)
    marking = second(test, fn -> mark(person, admin) end, [~s(UPDATE "users")])

    send(denial.pid, :go)
    assert {:ok, %{effect: "deny"}} = Task.await(denial, 25_000)
    assert {:error, :denied} = Task.await(marking, 25_000)
    assert {nil, [{"deny", "allowed"}]} = state(person)
  end
end
