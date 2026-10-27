# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorCensusTest do
  @moduledoc """
  Writes racing for the server's last athanor places (`CYFR_MAX_ATHANORS`),
  on connections of their own: inside the sandbox one shared connection
  would serialize them. Every write that can raise the number of active
  athanors counts it under the census lock (`Arca.AthanorCensus`), in the
  transaction that writes.

  On PostgreSQL every racer is held behind a transaction that takes the
  census lock and holds the athanors table against writes, until each
  racer is seen waiting on the census lock; then all of them race when it
  is let go. SQLite's one write lock admits one transaction at a time, so
  there the same cases run as concurrent processes and show parity, not
  the race.

  The cap is a stored setting, and a row written in a test's sandbox
  transaction is invisible to the racers' own connections, so it is
  written outside the sandbox, with the node's cached value dropped so the
  racers read it. Every person a case makes carries the case's run number
  in their address, and the setting, the people and every row of theirs
  are deleted outside the sandbox when the case ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.PlatformSettings, as: Store
  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, User}
  alias Arca.Test.{Adapter, LockWait}
  alias Ecto.Adapters.SQL.Sandbox
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @key "max_athanors"
  @racers 8

  setup do
    run = System.unique_integer([:positive])

    # The case owns the setting's row outright: it stores one and deletes
    # it, so there must be none to restore.
    unboxed(fn -> {:error, :not_found} = Store.get(@key) end)

    on_exit(fn ->
      unboxed(fn ->
        with {:ok, _} <- Store.get(@key) do
          {:ok, %{revision: revision}} = Store.all()
          {:ok, _} = Store.delete(@key, revision)
        end

        cleanup!(run)
      end)

      Store.invalidate(@key)
    end)

    {:ok, run: run}
  end

  test "the census lock is refused outside a transaction" do
    assert_raise RuntimeError, ~r/outside a transaction/, fn ->
      unboxed(&Arca.AthanorCensus.lock/0)
    end

    assert {:ok, :ok} = unboxed(fn -> Arca.Repo.transaction(&Arca.AthanorCensus.lock/0) end)
  end

  test "personal mints at the server's last two places: two land, and a refusal leaves no row",
       %{run: run} do
    owners = for i <- 1..@racers, do: person!(run, i)
    cap = cap!(2)

    answers = race(Enum.map(owners, fn owner -> fn -> Athanors.create(personal(owner)) end end))

    assert Enum.count(answers, &match?({:ok, _}, &1)) == 2
    assert Enum.count(answers, &(&1 == refused(cap))) == @racers - 2
    assert active() == cap

    for {owner, answer} <- Enum.zip(owners, answers), answer == refused(cap) do
      assert {:error, :not_found} = unboxed(fn -> Athanors.get_by_owner(owner.id) end)
    end
  end

  test "group mints at the server's last two places: two land, and a refusal leaves no row or seat",
       %{run: run} do
    creators = for i <- 1..@racers, do: person!(run, i)
    cap = cap!(2)

    answers =
      race(
        for {creator, i} <- Enum.with_index(creators, 1) do
          fn -> Athanors.create_group(creator.id, "Census #{i}", slug: "census-#{run}-g#{i}") end
        end
      )

    assert Enum.count(answers, &match?({:ok, _}, &1)) == 2
    assert Enum.count(answers, &(&1 == refused(cap))) == @racers - 2
    assert active() == cap

    for {creator, answer} <- Enum.zip(creators, answers) do
      {created, seats} = rows_of(creator.id)

      case answer do
        {:ok, group} ->
          assert created == [group.id]
          assert seats == [group.id]

        refusal ->
          assert refusal == refused(cap)
          assert {created, seats} == {[], []}
      end
    end
  end

  test "two reopens at the server's last place: one lands, the other stays archived",
       %{run: run} do
    groups = for i <- 1..2, do: archived_group!(person!(run, i), run, i)
    cap = cap!(1)

    answers = race(Enum.map(groups, fn group -> fn -> Athanors.unarchive(group) end end))

    assert Enum.count(answers, &match?({:ok, _}, &1)) == 1
    assert Enum.count(answers, &(&1 == refused(cap))) == 1
    assert active() == cap

    for {group, answer} <- Enum.zip(groups, answers), answer == refused(cap) do
      assert {:ok, %{status: "archived"}} = unboxed(fn -> Athanors.get(group.id) end)
    end
  end

  test "two allows at the server's last place: one lands, the other stays denied",
       %{run: run} do
    denied = for i <- 1..2, do: denied_owner!(run, i)
    cap = cap!(1)

    answers = race(Enum.map(denied, fn {user, _own} -> fn -> Users.allow(user) end end))

    assert Enum.count(answers, &match?({:ok, _}, &1)) == 1
    assert Enum.count(answers, &(&1 == refused(cap))) == 1
    assert active() == cap

    for {{user, own}, answer} <- Enum.zip(denied, answers), answer == refused(cap) do
      assert {:ok, %{status: "denied"}} = unboxed(fn -> Users.get(user.id) end)
      assert {:ok, %{status: "archived"}} = unboxed(fn -> Athanors.get(own.id) end)
    end
  end

  test "a reopen and a mint at the server's last place: one lands", %{run: run} do
    group = archived_group!(person!(run, 1), run, 1)
    owner = person!(run, 2)
    cap = cap!(1)

    answers =
      race([
        fn -> Athanors.unarchive(group) end,
        fn -> Athanors.create(personal(owner)) end
      ])

    assert Enum.count(answers, &match?({:ok, _}, &1)) == 1
    assert Enum.count(answers, &(&1 == refused(cap))) == 1
    assert active() == cap
  end

  # ---- the race ----------------------------------------------------------------

  # Run each call on a connection of its own and answer what each answered,
  # in order. On PostgreSQL every call is held until all of them are seen
  # waiting on the census lock.
  defp race(calls) do
    if Adapter.postgres?() do
      holder = holding()
      racers = Enum.map(calls, &racer/1)

      for _ <- racers do
        assert_receive {:backend, backend}, 15_000
        LockWait.await_lock_wait!(backend, ["pg_advisory_xact_lock"], timeout_ms: 15_000)
      end

      release(holder)
      Enum.map(racers, &Task.await(&1, 30_000))
    else
      calls |> Enum.map(&racer/1) |> Enum.map(&Task.await(&1, 30_000))
    end
  end

  defp racer(call) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        if Adapter.postgres?(), do: send(test, {:backend, backend_pid()})
        call.()
      end)
    end)
  end

  # A transaction of its own that takes the census lock and holds the
  # athanors table against writes, open until `release/1`. The table lock
  # holds a racer that counted without waiting for the census lock before
  # its row lands, so every racer is held, whichever statement holds it.
  defp holding do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            Arca.AthanorCensus.lock()
            Arca.Repo.query!("LOCK TABLE athanors IN SHARE MODE")
            send(test, :holding)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :holding, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    assert {:ok, :ok} = Task.await(task, 30_000)
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # ---- fixtures ----------------------------------------------------------------

  # Store the cap as the active count now plus `places`, outside the
  # sandbox, and drop the node's cached value so the racers read it.
  defp cap!(places) do
    cap = active() + places

    unboxed(fn ->
      {:ok, %{revision: revision}} = Store.all()
      {:ok, _} = Store.put(@key, cap, revision, "test")
    end)

    Store.invalidate(@key)
    cap
  end

  defp refused(cap), do: {:error, {:limit_reached, :max_athanors, cap}}

  defp active do
    {:ok, count} = unboxed(&Athanors.count/0)
    count
  end

  # A real person row, so a mint that holds them holds a row: the row and
  # its sign-in method alone, with no athanor yet, so the case's own mints
  # are the only athanors they hold.
  defp person!(run, i) do
    now = DateTime.utc_now()
    subject = "census-#{run}-#{i}"

    {:ok, %{id: user_id}} =
      unboxed(fn ->
        Arca.Test.People.mint(
          Prima.Actor.system(),
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            email: "census#{run}-#{i}@example.com",
            email_verified: true,
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
      end)

    {:ok, user} = unboxed(fn -> Users.get(user_id) end)
    user
  end

  defp personal(owner) do
    %{
      kind: "person",
      name: "Census #{owner.id}",
      slug: "census-" <> String.downcase(String.replace(owner.id, ~r/[^a-zA-Z0-9]/, "")),
      owner_user_id: owner.id,
      created_by: owner.id
    }
  end

  # A group the person made, archived; made before the cap is stored.
  defp archived_group!(creator, run, i) do
    unboxed(fn ->
      {:ok, group} =
        Athanors.create(%{
          kind: "group",
          name: "Census #{i}",
          slug: "census-#{run}-a#{i}",
          created_by: creator.id
        })

      {:ok, archived} = Athanors.archive(group)
      archived
    end)
  end

  # A person with their own athanor and a seat in it, as sign-in leaves
  # them, then denied, which archives the athanor.
  defp denied_owner!(run, i) do
    user = person!(run, i)

    unboxed(fn ->
      {:ok, own} = Athanors.create(personal(user))
      {:ok, user} = Users.set_personal_athanor(user, own.id)
      {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: own.id, added_by: "system")
      {:ok, denied} = Users.deny(user)
      {denied, own}
    end)
  end

  # The athanors the person created and the athanors they sit in.
  defp rows_of(user_id) do
    unboxed(fn ->
      {Arca.Repo.all(from(a in Athanor, where: a.created_by == ^user_id, select: a.id)),
       Arca.Repo.all(from(m in Membership, where: m.user_id == ^user_id, select: m.athanor_id))}
    end)
  end

  defp cleanup!(run) do
    users =
      Arca.Repo.all(from(u in User, where: like(u.email, ^"census#{run}-%"), select: u.id))

    athanors =
      Arca.Repo.all(
        from(a in Athanor,
          where: a.created_by in ^users or a.owner_user_id in ^users,
          select: a.id
        )
      )

    Arca.Repo.delete_all(
      from(m in Membership, where: m.user_id in ^users or m.athanor_id in ^athanors)
    )

    Arca.Repo.delete_all(from(i in ExternalIdentity, where: i.user_id in ^users))
    Arca.Repo.delete_all(from(u in User, where: u.id in ^users))
    Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^athanors))
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
