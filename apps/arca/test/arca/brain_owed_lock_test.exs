# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BrainOwedLockTest do
  @moduledoc """
  What a program turn owes its brain is read in one view that holds the
  turn's row against its writers (`Arca.TurnStorage.brain_owed/2`), on
  PostgreSQL under real concurrency. It runs outside the sandbox, on
  connections of its own: inside it one shared connection would serialize
  the reader and the writer the test is about. A writer of the turn waits
  for the read to end, so a result and a post committed around the read
  are both seen or neither is.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Message, Thread, Turn, TurnStep}
  alias Arca.TurnStorage
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    actor = Arca.Test.Actor.local()

    {thread, turn} =
      unboxed(fn ->
        {:ok, thread} = Arca.Test.Days.thread(actor)

        {:ok, %{turn: turn}} =
          TurnStorage.accept_message(actor, thread.id, %{
            message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
            turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
          })

        {:ok, turn} = TurnStorage.start(actor, turn.id, %{fence: turn.fence, recovery_limit: 3})
        {thread, turn}
      end)

    on_exit(fn -> unboxed(fn -> delete_thread!(actor.athanor_id, thread.id) end) end)
    {:ok, actor: actor, turn: turn}
  end

  @tag :postgres
  test "a writer of the turn waits while what the turn owes is read, and lands after it",
       %{actor: actor, turn: turn} do
    test = self()

    # The read's transaction is held open after the read, as a read that a
    # commit could straddle would be.
    reader =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            {:ok, _owed} = TurnStorage.brain_owed(actor, turn.id)
            send(test, :read)

            receive do
              :release -> :ok
            after
              30_000 -> Arca.Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(reader.pid), do: Process.exit(reader.pid, :kill) end)
    assert_receive :read, 5_000

    writer =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(test, {:writing, backend})
          TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})
        end)
      end)

    on_exit(fn -> if Process.alive?(writer.pid), do: Process.exit(writer.pid, :kill) end)
    assert_receive {:writing, backend}, 5_000

    # The writer waits on the turn's row the read holds.
    Arca.Test.LockWait.await_lock_wait!(backend, [~s("turns")])
    send(reader.pid, :release)
    assert {:ok, :ok} = Task.await(reader, 10_000)
    assert {:ok, %{kind: "model"}} = Task.await(writer, 10_000)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp delete_thread!(athanor_id, thread_id) do
    turn_ids =
      Arca.Repo.all(
        from(t in Turn,
          where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
          select: t.id
        )
      )

    Arca.Repo.delete_all(from(s in TurnStep, where: s.turn_id in ^turn_ids))
    Arca.Repo.delete_all(from(m in Message, where: m.thread_id == ^thread_id))
    Arca.Repo.delete_all(from(t in Turn, where: t.id in ^turn_ids))
    Arca.Repo.delete_all(from(t in Thread, where: t.id == ^thread_id))
  end
end
