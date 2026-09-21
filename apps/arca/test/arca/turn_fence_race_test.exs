# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnFenceRaceTest do
  @moduledoc """
  The fence under real concurrency. These run outside the sandbox, on
  connections of their own: inside it one shared connection would serialize
  the writers the test is about. A runner-owned write holds the turn row
  until it commits, so a host transition waits behind it; once the fence has
  moved, the runner that held it writes nothing more; and of two transitions
  that read the same fence, only one lands.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Message, Thread, ThreadSubscription, Turn, TurnStep}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    actor = Arca.Test.Actor.local()

    {thread, turn} =
      unboxed(fn ->
        {:ok, thread} = Threads.create(actor)

        {:ok, %{turn: turn}} =
          TurnStorage.accept_message(actor, thread.id, %{
            message: %{author: actor.user_id, content: "@aqua go"},
            turn: %{agent: "aqua", requested_by: actor.user_id}
          })

        {thread, turn}
      end)

    on_exit(fn -> unboxed(fn -> delete_thread!(actor.athanor_id, thread.id) end) end)
    {:ok, actor: actor, turn: turn}
  end

  test "a takeover waits behind a runner's write, lands after it, and the runner writes nothing more",
       %{actor: actor, turn: turn} do
    test = self()

    runner =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            {:ok, step} =
              TurnStorage.put_step(actor, turn.id, %{
                kind: "model",
                fence: turn.fence
              })

            send(test, {:holding, step.id})

            receive do
              :commit -> step
            end
          end)
        end)
      end)

    assert_receive {:holding, step_id}, 5_000

    host =
      Task.async(fn ->
        unboxed(fn ->
          TurnStorage.supersede(actor, turn.id, %{fence: turn.fence})
        end)
      end)

    # The runner's transaction holds the turn row; the host cannot move it yet.
    refute Task.yield(host, 300)

    send(runner.pid, :commit)
    assert {:ok, %{id: ^step_id}} = Task.await(runner, 5_000)
    assert {:ok, taken} = Task.await(host, 25_000)
    assert taken.fence != turn.fence

    assert {:error, :superseded} =
             unboxed(fn ->
               TurnStorage.put_step(actor, turn.id, %{
                 kind: "model",
                 fence: turn.fence
               })
             end)

    assert [^step_id] = unboxed(fn -> step_ids(actor.athanor_id, turn.id) end)
  end

  test "of two transitions that read the same fence, one lands", %{actor: actor, turn: turn} do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          unboxed(fn ->
            TurnStorage.supersede(actor, turn.id, %{fence: turn.fence})
          end)
        end)
      end)
      |> Enum.map(&Task.await(&1, 25_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :superseded})) == 1
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp step_ids(athanor_id, turn_id) do
    Arca.Repo.all(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
        select: s.id
      )
    )
  end

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
    Arca.Repo.delete_all(from(f in ThreadSubscription, where: f.thread_id == ^thread_id))
    Arca.Repo.delete_all(from(t in Thread, where: t.id == ^thread_id))
  end
end
