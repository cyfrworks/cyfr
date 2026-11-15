# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsersMarkingRaceTest do
  @moduledoc """
  A person made an administrator while the door removes their allow or
  denies them, and administrators marked and cleared at once, on real
  connections outside the sandbox, in every order. Each change takes the
  administrators' lock first (`Arca.Users.lock_admins/0`), so whichever
  starts second waits for the first to commit and decides on what it
  wrote: a marking that committed first is seen and the removal or deny is
  refused; a removal that committed first is written over by the marking's
  allow; a deny that committed first refuses the marking's allow, and the
  marking rolls back. However many such changes run at once, each is
  answered and none fails on a deadlock. On PostgreSQL the second waits on
  the advisory lock; on SQLite on the write lock the first holds.
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
    Users.with_admins_locked(server(), fn marked? ->
      if marked?.({"identifier", person.identifier}) do
        {:error, :platform_admin}
      else
        hold.()
        {:ok, entry} = Doors.find(server(), "identifier", person.identifier)
        :ok = Doors.delete(server(), entry.id)
        {:ok, :removed}
      end
    end)
  end

  defp deny(person, hold \\ fn -> :ok end) do
    Users.with_admins_locked(server(), fn marked? ->
      if marked?.({"identifier", person.identifier}) do
        {:error, :platform_admin}
      else
        hold.()
        {:ok, entry} = Doors.find(server(), "identifier", person.identifier)
        Doors.update(server(), entry.id, %{effect: "deny", added_by: "usr_ops"})
      end
    end)
  end

  # The wait every change of the administrators makes behind another.
  @admins_wait ["pg_advisory_xact_lock"]

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
    if postgres?(), do: LockWait.await_lock_wait!(waiting, fragments, event: "advisory")
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

  test "a marking that holds the administrators' lock: the removal that waits is refused", %{
    admin: admin,
    person: person
  } do
    test = self()
    marking = first(fn -> mark(person, admin, holding(test)) end)
    removal = second(test, fn -> remove(person) end, @admins_wait)

    send(marking.pid, :go)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {:error, :platform_admin} = Task.await(removal, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a removal that holds the administrators' lock: the marking that waits writes the allow again",
       %{
         admin: admin,
         person: person
       } do
    test = self()
    removal = first(fn -> remove(person, holding(test)) end)
    marking = second(test, fn -> mark(person, admin) end, @admins_wait)

    send(removal.pid, :go)
    assert {:ok, :removed} = Task.await(removal, 25_000)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a marking that holds the administrators' lock: the deny that waits is refused", %{
    admin: admin,
    person: person
  } do
    test = self()
    marking = first(fn -> mark(person, admin, holding(test)) end)
    denial = second(test, fn -> deny(person) end, @admins_wait)

    send(marking.pid, :go)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {:error, :platform_admin} = Task.await(denial, 25_000)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(person)
  end

  test "a deny that holds the administrators' lock: the marking that waits is refused and writes nothing",
       %{admin: admin, person: person} do
    test = self()
    denial = first(fn -> deny(person, holding(test)) end)
    marking = second(test, fn -> mark(person, admin) end, @admins_wait)

    send(denial.pid, :go)
    assert {:ok, %{effect: "deny"}} = Task.await(denial, 25_000)
    assert {:error, :denied} = Task.await(marking, 25_000)
    assert {nil, [{"deny", "allowed"}]} = state(person)
  end

  # A clearing of `person`'s mark as `admin` asks it.
  defp clear(person, admin),
    do: Users.set_platform_admin(server(), person.user_id, false, by: admin.user_id)

  test "a marking holds while a clearing and a later marking start: both wait, both are answered",
       %{admin: admin, person: person} do
    other = person!(false)
    {:ok, _allow} = unboxed(fn -> allow(other.identifier) end)
    test = self()

    # The marking of `person` decides and holds; the clearing of `person`
    # reads the administrators before it commits, and the marking of
    # `other` after: neither locks a row the other holds.
    marking = first(fn -> mark(person, admin, holding(test)) end)
    clearing = second(test, fn -> clear(person, admin) end, @admins_wait)
    later = second(test, fn -> mark(other, admin) end, @admins_wait)

    send(marking.pid, :go)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(marking, 25_000)
    assert {:ok, %{platform_admin_at: nil}} = Task.await(clearing, 25_000)
    assert {:ok, %{platform_admin_at: %DateTime{}}} = Task.await(later, 25_000)
    assert {nil, [{"allow", "allowed"}]} = state(person)
    assert {%DateTime{}, [{"allow", "allowed"}]} = state(other)
  end

  test "three changes of the administrators started at once, in every order, are each answered" do
    acts = [:mark, :clear, :remove]

    for order <- [acts, Enum.reverse(acts), [:clear, :mark, :remove], [:remove, :mark, :clear]],
        _round <- 1..2 do
      admin = person!(true)
      person = person!(false)
      {:ok, _allow} = unboxed(fn -> allow(person.identifier) end)

      changes = %{
        mark: fn -> mark(person, admin) end,
        clear: fn -> clear(admin, admin) end,
        remove: fn -> remove(person) end
      }

      answers =
        order
        |> Enum.map(&{&1, Task.async(fn -> unboxed(changes[&1]) end)})
        |> Map.new(fn {act, task} -> {act, Task.await(task, 25_000)} end)

      # Each is answered, none by a failed statement such as a deadlock:
      # the marking is refused only when the clearing came first and took
      # the asking administrator's mark, the clearing only while they stood
      # alone, the removal only once the person was marked.
      assert match?({:ok, %{platform_admin_at: %DateTime{}}}, answers.mark) or
               answers.mark == {:error, :not_admin},
             inspect(answers)

      assert match?({:ok, %{platform_admin_at: nil}}, answers.clear) or
               answers.clear == {:error, :last_admin},
             inspect(answers)

      assert answers.remove in [{:ok, :removed}, {:error, :platform_admin}], inspect(answers)

      {person_mark, person_entries} = state(person)
      {admin_mark, _entries} = state(admin)

      # A marked person's allow stands whichever change came first.
      assert person_mark != nil == match?({:ok, _}, answers.mark), inspect(answers)
      if person_mark, do: assert(person_entries == [{"allow", "allowed"}])
      if answers.remove == {:error, :platform_admin}, do: assert(person_mark)
      assert answers.clear == {:error, :last_admin} == (admin_mark != nil), inspect(answers)
    end
  end
end
