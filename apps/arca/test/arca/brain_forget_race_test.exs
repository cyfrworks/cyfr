# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BrainForgetRaceTest do
  @moduledoc """
  A home's cleanup (`Arca.ThreadStorage.forget_sessions/2`) chooses the
  threads it may reach before it takes their locks, and decides which of
  them it clears from what it reads under the locks: a turn pinned to the
  row that ended while the cleanup waited, its thread's session committed
  on another row meanwhile, is no longer the row's, and that session, its
  generation and its transcript are left as they are. These run outside
  the sandbox, on connections of their own, with the successor's write
  holding the athanor's lock until the cleanup is seen waiting on it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag timeout: 60_000

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  test "a cleanup of an old row leaves the session a successor row committed while it waited" do
    athanor_id = "ath_forget_race_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: athanor_id)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.Test.TenantTables.delete_all_for(actor)
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id))
      end)
    end)

    {thread, old, new, pinned} =
      unboxed(fn ->
        Arca.Test.Actor.ensure_athanor_row(athanor_id)
        {:ok, thread} = Arca.Test.Days.thread(actor)
        old = row!(actor, "old")
        new = row!(actor, "new")
        {thread, old, new, running!(actor, thread, old)}
      end)

    test = self()

    # The turn pinned to the old row ends and a turn on the new row keeps
    # its session, in one transaction that holds the turn and then the
    # athanor's row, as a turn's writes take them, until it is told to go.
    successor =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(t in Arca.Schemas.Turn, where: t.id == ^pinned.id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            Threads.lock_athanor!(actor)
            send(test, :held)

            receive do
              :go -> :ok
            after
              10_000 -> flunk("the successor was never told to go")
            end

            {1, _} =
              Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^pinned.id),
                set: [status: "completed"]
              )

            running!(actor, thread, new)

            {:ok, %{seen: false}} =
              TurnStorage.commit_events(actor, %{thread: thread.id, agent: "aqua", turn: nil}, %{
                events: [],
                position:
                  {:session,
                   %{
                     generation: 0,
                     boot: "successor",
                     hello: true,
                     seq: 1,
                     row_id: new.id,
                     epoch: new.epoch,
                     silence_ms: 1_800_000,
                     session: "6f1e2d3c-0000-4968-8776-000000000002"
                   }}
              })

            {:ok, row} = Threads.get(actor, thread.id)
            row
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(successor.pid), do: Process.exit(successor.pid, :kill) end)
    assert_receive :held, 5_000

    cleanup =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(test, {:cleaning, backend})
          Threads.forget_sessions(actor, old.id)
        end)
      end)

    on_exit(fn -> if Process.alive?(cleanup.pid), do: Process.exit(cleanup.pid, :kill) end)
    assert_receive {:cleaning, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend, ["athanors"])
    send(successor.pid, :go)

    assert {:ok, committed} = Task.await(successor, 10_000)
    result = Task.await(cleanup, 10_000)
    owed = unboxed(fn -> Arca.Outbox.pending(actor, "brain_cleanup", "brain_forget") end)
    after_cleanup = unboxed(fn -> Threads.get(actor, thread.id) end)

    assert {result, after_cleanup, owed} == {{:ok, []}, {:ok, committed}, {:ok, []}}
  end

  defp row!(actor, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(actor, %{
        name: name,
        cap: 0,
        transport: "program",
        mark: "driven",
        home: "kept",
        url: nil,
        config_json:
          Jason.encode!(%{
            "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
            "env" => %{}
          })
      })

    row
  end

  # An open turn of "aqua" in `thread` pinned to `row`.
  defp running!(actor, thread, row) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [status: "running"]
      )

    {:ok, _} = TurnStorage.pin_program(actor, turn.id, row.id, %{fence: turn.fence})
    turn
  end
end
