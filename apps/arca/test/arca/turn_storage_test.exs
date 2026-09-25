# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorageTest do
  @moduledoc """
  The turn store owns persistence and the transactional guards, not
  policy: its vocabulary is `Prima.TurnState`'s, it keeps no recovery cap
  of its own, and the limit a turn is held to is the one its row stores —
  written from the caller's policy when the turn starts, carried by a
  clone, and spent one recovery at a time under the turn's lock, so two
  members recovering one turn from the same fence spend one recovery.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Message, Thread, ThreadSubscription, Turn}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Ecto.Adapters.SQL.Sandbox

  @standing %{grant: :stored, verify: &Arca.Test.Actor.admits/1}

  describe "the vocabulary and the policy" do
    test "the statuses are Prima's, and the store keeps no recovery cap" do
      assert TurnStorage.statuses() == Prima.TurnState.statuses()
      assert TurnStorage.open_statuses() == Prima.TurnState.open_statuses()
      assert TurnStorage.terminal_statuses() == Prima.TurnState.terminal_statuses()

      Code.ensure_loaded!(TurnStorage)
      refute function_exported?(TurnStorage, :recovery_cap, 0)
    end

    test "every transaction takes the write lock through the locking helper" do
      source = File.read!(Path.expand("../../lib/arca/turn_storage.ex", __DIR__))

      refute source =~ "Arca.Repo.transaction(",
             "a turn transition opens its transaction with Arca.Repo.locking_transaction/2"
    end
  end

  describe "the stored limit" do
    setup do
      :ok = Sandbox.checkout(Arca.Repo)
      Sandbox.mode(Arca.Repo, {:shared, self()})
      Arca.Test.Actor.athanor!()
      actor = Arca.Test.Actor.local()
      {:ok, thread} = Threads.create(actor)
      {:ok, actor: actor, thread: thread}
    end

    test "an accepted turn stores none; its start stores the caller's, and a clone carries it",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)
      assert turn.recovery_limit == nil

      {:ok, started} = TurnStorage.start(actor, turn.id, %{fence: turn.fence, recovery_limit: 5})
      assert started.recovery_limit == 5

      {:ok, %{turn: clone}} =
        TurnStorage.open_clone_turn(actor, turn.id, %{role: "helper", fence: started.fence})

      assert clone.recovery_limit == 5
    end

    test "each recovery spends one of the stored limit, and the next past it is refused",
         %{actor: actor, thread: thread} do
      turn = accept!(actor, thread)
      {:ok, started} = TurnStorage.start(actor, turn.id, %{fence: turn.fence, recovery_limit: 2})

      {:ok, first} =
        TurnStorage.recover(actor, turn.id, Map.put(@standing, :fence, started.fence))

      {:ok, second} = TurnStorage.recover(actor, turn.id, Map.put(@standing, :fence, first.fence))
      assert second.recovery_attempts == 2

      assert {:error, :recovery_exhausted} =
               TurnStorage.recover(
                 actor,
                 turn.id,
                 Map.merge(@standing, %{fence: second.fence, recovery_limit: 10})
               )

      assert %{recovery_attempts: 2, recovery_limit: 2} = Arca.Repo.get!(Turn, turn.id)
    end
  end

  # Two members recovering one turn from the fence both read: the first
  # takes the turn row and raises the fence, and the second, once it holds
  # the row, reads the raised fence and moves nothing. The loser's refusal
  # is not pinned: on SQLite it may be refused for the write lock first.
  describe "under the lock" do
    setup do
      actor = Arca.Test.Actor.local()

      {thread, turn} =
        unboxed(fn ->
          Arca.Test.Actor.athanor!()
          {:ok, thread} = Threads.create(actor)
          turn = accept!(actor, thread)

          {:ok, started} =
            TurnStorage.start(actor, turn.id, %{fence: turn.fence, recovery_limit: 3})

          {thread, started}
        end)

      on_exit(fn -> unboxed(fn -> delete_thread!(actor.athanor_id, thread.id) end) end)
      {:ok, actor: actor, turn: turn}
    end

    test "of two recoveries from one fence, one lands and one recovery is spent",
         %{actor: actor, turn: turn} do
      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            unboxed(fn ->
              TurnStorage.recover(actor, turn.id, Map.put(@standing, :fence, turn.fence))
            end)
          end)
        end)
        |> Enum.map(&Task.await(&1, 25_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      assert %{recovery_attempts: 1, fence: fence} =
               unboxed(fn -> Arca.Repo.get!(Turn, turn.id) end)

      assert fence == turn.fence + 1
    end
  end

  defp accept!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: actor.user_id}
      })

    turn
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

    Arca.Repo.delete_all(from(m in Message, where: m.thread_id == ^thread_id))
    Arca.Repo.delete_all(from(t in Turn, where: t.id in ^turn_ids))
    Arca.Repo.delete_all(from(f in ThreadSubscription, where: f.thread_id == ^thread_id))
    Arca.Repo.delete_all(from(t in Thread, where: t.id == ^thread_id))
  end
end
