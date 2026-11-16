# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.ThreadDeleteTest do
  @moduledoc """
  A deletion through the thread tool that turns keep starting under, round
  after round of its choosing them, refuses as the thread in use, in a
  sentence of its own the person can act on, never the turn queue's. It
  runs outside the sandbox, each writer on a connection of its own and
  each wait seen on its real lock (PostgreSQL only).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag timeout: 60_000

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend! do
    %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # An athanor no other case names, its row committed, whose rows go with
  # it when the case ends.
  setup do
    athanor_id = "ath_delete_in_use_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: athanor_id)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.Test.TenantTables.delete_all_for(actor)
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id))
      end)
    end)

    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor_id) end)

    ctx =
      Sanctum.Context.build(
        user_id: actor.user_id,
        provider: "oidc",
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, actor: actor, ctx: ctx}
  end

  # A turn of the member's in `thread`, accepted and never run.
  defp turn!(actor, thread) do
    unboxed(fn ->
      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go"},
          turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
        })

      turn
    end)
  end

  # `turn` held by a transaction of its own until it is released, with
  # that transaction's backend.
  defp hold(turn) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(t in Arca.Schemas.Turn, where: t.id == ^turn.id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(test, {:held, turn.id, backend!()})

            receive do
              :release -> :ok
            after
              30_000 -> Arca.Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    turn_id = turn.id
    assert_receive {:held, ^turn_id, backend}, 5_000
    {task, backend}
  end

  defp release({task, _backend}) do
    send(task.pid, :release)
    assert {:ok, :ok} = Task.await(task, 10_000)
  end

  # Until `waiter` waits on a lock the backend `blocker` holds.
  defp await_blocked!(waiter, blocker) do
    Prima.Test.Wait.wait_until(
      fn ->
        unboxed(fn ->
          %{rows: [[blocked?]]} =
            Arca.Repo.query!("SELECT $2::integer = ANY(pg_blocking_pids($1))", [waiter, blocker])

          blocked?
        end)
      end,
      5_000,
      "backend #{waiter} to wait on backend #{blocker}"
    )
  end

  test "a deletion that turns keep starting under refuses as the thread in use, in its own words",
       %{actor: actor, ctx: ctx} do
    {:ok, room} = unboxed(fn -> Arca.Test.Days.thread(actor) end)
    {:ok, child} = unboxed(fn -> Threads.crew_thread(actor, room.id, "planner") end)
    first = hold(turn!(actor, child))
    test = self()

    deletion =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:deleting, backend!()})

          Aqua.Providers.Thread.handle("thread", ctx, %{
            "action" => "delete",
            "thread" => room.id
          })
        end)
      end)

    assert_receive {:deleting, deleting}, 5_000

    # In each of its three rounds the deletion waits on a turn it chose,
    # and meanwhile another turn starts in the member's thread.
    last =
      Enum.reduce(1..3, first, fn _round, {_task, held} = blocker ->
        await_blocked!(deleting, held)
        next = hold(turn!(actor, child))
        release(blocker)
        next
      end)

    assert {:error, reason} = Task.await(deletion, 15_000)
    release(last)

    assert reason == :thread_in_use

    assert Sanctum.Refusals.render(reason) ==
             "This thread is in use — try deleting it again in a moment"

    refute Sanctum.Refusals.render(reason) == Sanctum.Refusals.render(:busy)
    assert {:ok, %{kind: "daily"}} = unboxed(fn -> Threads.get(actor, room.id) end)
  end
end
