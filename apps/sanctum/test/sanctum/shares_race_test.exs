# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SharesRaceTest do
  @moduledoc """
  A use of a share racing a narrowing of its audience, each on a
  connection of its own: inside the sandbox one shared connection would
  serialize what the case is about. A narrowing takes no lock of its own,
  so the use's claim, which reads the share's row under its lock, holds it
  to the audience the resolution admitted the person under. On PostgreSQL
  the claim is seen waiting on the row the holder took; on SQLite the
  holder's write lock is what it waits for. Every row the case writes is
  removed when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Test.Shares, as: Fixture
  alias Ecto.Adapters.SQL.Sandbox

  @inside %{uri: URI.parse("https://api.example.com/v1/quotes"), method: "GET"}

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

  # A shared thread `creator` made, recorded for the purge.
  defp thread!(made, creator) do
    {:ok, thread} =
      unboxed(fn ->
        Arca.SharedThreads.create(Prima.Actor.system(), %{title: "Desk", created_by: creator})
      end)

    :ok = Agent.update(made, &[%{thread: thread} | &1])
    thread
  end

  # The threads go first: their seats name the people purged after them.
  defp purge!(made) do
    {threads, owners} = Enum.split_with(made, &Map.has_key?(&1, :thread))

    for %{thread: thread} <- threads,
        do: Arca.Repo.delete_all(from(t in Arca.Schemas.SharedThread, where: t.id == ^thread.id))

    for %{athanor: athanor, user: user} <- owners do
      {:ok, _} = Arca.Test.TenantTables.delete_all_for(Prima.Actor.in_athanor(athanor.id))
      Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id))

      if user do
        Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user.id))
      end
    end
  end

  # The person signed in to their own athanor.
  defp context(%{user: user, athanor: athanor}) do
    %{Sanctum.TestContext.local() | user_id: user.id, athanor_id: athanor.id}
  end

  test "a narrowing that lands while a use waits on the share's row refuses the use: not " <>
         "offered, with nothing counted or unsealed",
       %{made: made} do
    terry = owned!(made)
    alice = owned!(made)
    thread = thread!(made, terry.user.id)
    entry = unboxed(fn -> Fixture.entry!(terry.actor, %{field_names: ~s(["KEY"])}) end)
    share = unboxed(fn -> Fixture.share!(terry.actor, entry.id) end)

    {:ok, %{source: source}} =
      unboxed(fn -> Arca.Shares.get_for_source(Prima.Actor.system(), share.id) end)

    {:ok, approved} = Sanctum.VaultReader.binding_digest(source)
    parent = self()

    # The holder takes the share's row as a revoke would, waits until the
    # use is seen waiting on it, then narrows the share to a thread Alice
    # is not in, and commits.
    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(s in Arca.Schemas.Share, where: s.id == ^share.id, select: s.id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(parent, {:held, self()})

            receive do
              :narrow ->
                Arca.Shares.set_audience(
                  terry.actor,
                  share.id,
                  %{audience: "everyone", thread_id: nil},
                  %{audience: "thread", thread_id: thread.id}
                )
            end
          end)
        end)
      end)

    assert_receive {:held, holding}, 10_000

    use =
      Task.async(fn ->
        unboxed(fn ->
          if Arca.Test.Adapter.postgres?() do
            %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, pid})
          end

          Sanctum.Shares.resolve(
            context(alice),
            share.id,
            approved,
            @inside,
            {:field, "KEY", "KEY"}
          )
        end)
      end)

    if Arca.Test.Adapter.postgres?() do
      assert_receive {:backend, pid}, 10_000
      :ok = Arca.Test.LockWait.await_lock_wait!(pid, ["shares", "FOR SHARE"])
    else
      assert Task.yield(use, 300) == nil
    end

    send(holding, :narrow)
    assert {:ok, {:ok, %{audience: "thread"}}} = Task.await(holder, 15_000)
    assert Task.await(use, 15_000) == {:error, :not_offered}

    assert {:ok, %{people: [], totals: []}} =
             unboxed(fn -> Arca.ShareUsage.usage(terry.actor, share.id, 1) end)

    assert {:ok, %{last_used_at: nil}} =
             unboxed(fn -> Arca.VaultStorage.get(terry.actor, entry.id) end)
  end
end
