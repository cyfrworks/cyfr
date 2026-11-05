# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionLockOrderTest do
  @moduledoc """
  Every execution write takes the execution row before any attempt row,
  so two writes of one run wait on each other in one order and never
  deadlock: a lapse of a run against the run's own terminal write, and a
  lapse of a turn's root against the turn's end. A turn's writers take
  the turn before its thread, an archive of the thread among them, and a
  room's deletion holds the athanor's lock a child's creation waits on.
  These run outside the sandbox, on connections of their own, with the
  run's attempt held by a third transaction so both writes are seen
  waiting before either goes on; a PostgreSQL deadlock would abort one of
  them with a database error.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.Schemas.{
    BudgetReservation,
    Execution,
    ExecutionAttempt,
    ExecutionEvent,
    Message,
    Thread,
    Turn,
    TurnStep
  }

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

  # `fun` on a connection of its own, telling the test its backend first.
  defp waiting(tag, fun) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {tag, backend!()})
          fun.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {^tag, backend}, 5_000
    {task, backend}
  end

  # The attempt held by a transaction of its own until it is released.
  defp hold_attempt(attempt) do
    test = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(a in ExecutionAttempt, where: a.attempt == ^attempt)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(test, :held)

            receive do
              :release -> :ok
            after
              30_000 -> Arca.Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(blocker.pid), do: Process.exit(blocker.pid, :kill) end)
    assert_receive :held, 5_000
    blocker
  end

  defp release(blocker) do
    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
  end

  defp delete_run!(execution_id) do
    Arca.Repo.delete_all(from(e in ExecutionEvent, where: e.execution_id == ^execution_id))
    Arca.Repo.delete_all(from(a in ExecutionAttempt, where: a.execution_id == ^execution_id))

    Arca.Repo.delete_all(
      from(r in BudgetReservation, where: r.root_execution_id == ^execution_id)
    )

    Arca.Repo.delete_all(from(e in Execution, where: e.id == ^execution_id))
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
    Arca.Repo.delete_all(from(t in Thread, where: t.id == ^thread_id))
  end

  defp lapse_opts(attempt),
    do:
      Arca.Test.Actor.stored()
      |> Keyword.put(:attempt, attempt)
      |> Keyword.put(:verify, &Arca.Test.Actor.verify/1)

  @ended %{completed_at: nil, duration_ms: 1, error_message: "lapsed"}

  test "a lapse and the run's own terminal write wait on each other in one order" do
    athanor_id = Arca.Test.Actor.athanor_id()
    actor = Prima.Actor.in_athanor(athanor_id)
    id = "exec_lock_order_#{System.unique_integer([:positive])}"
    on_exit(fn -> unboxed(fn -> delete_run!(id) end) end)

    {:ok, %{execution: row}} =
      unboxed(fn ->
        Arca.Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.probe:1.0.0",
            user_id: "usr_test",
            athanor_id: athanor_id,
            component_type: "catalyst",
            origin: :programmatic
          },
          Arca.Test.Actor.standing(athanor_id)
        )
      end)

    attempt = row.current_attempt
    ended = %{@ended | completed_at: DateTime.utc_now()}

    log =
      capture_log(fn ->
        blocker = hold_attempt(attempt)

        {lapse, lapse_backend} =
          waiting(:lapse, fn ->
            Arca.Execution.mark_failed_if_running(id, ended, lapse_opts(attempt))
          end)

        Arca.Test.LockWait.await_lock_wait!(lapse_backend, ["execution_attempts"])

        {ending, ending_backend} =
          waiting(:ending, fn ->
            Arca.Execution.record_end(
              actor,
              id,
              "completed",
              Map.take(ended, [:completed_at, :duration_ms]),
              attempt,
              Keyword.put(Arca.Test.Actor.stored(), :verify, &Arca.Test.Actor.verify/1)
            )
          end)

        Arca.Test.LockWait.await_lock_wait!(ending_backend, [])
        release(blocker)

        # The lapse took the row first, so the end finds it no longer open.
        assert {1, seq} = Task.await(lapse, 10_000)
        assert is_integer(seq)
        assert {:error, :not_running} = Task.await(ending, 10_000)
      end)

    refute log =~ "deadlock", log
    assert %Execution{status: "failed"} = unboxed(fn -> Arca.Repo.get!(Execution, id) end)
  end

  test "a lapse of a turn's root and the turn's end wait on each other in one order" do
    actor = Arca.Test.Actor.local()
    budget_id = "bgt_lock_order_#{System.unique_integer([:positive])}"

    {thread, turn} =
      unboxed(fn ->
        {:ok, thread} = Threads.create(actor)

        {:ok, %{turn: turn}} =
          TurnStorage.accept_message(actor, thread.id, %{
            message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
            turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
          })

        {thread, turn}
      end)

    root_id = "exec_lock_order_root_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        delete_thread!(actor.athanor_id, thread.id)
        delete_run!(root_id)
      end)
    end)

    {turn, attempt} =
      unboxed(fn ->
        {:ok, %{attempt: attempt}} =
          Arca.Execution.admit(
            %{
              id: root_id,
              reference: "agent:local.aqua",
              user_id: actor.user_id,
              athanor_id: actor.athanor_id,
              component_type: "agent",
              kind: "turn",
              turn_id: turn.id,
              origin: :interactive
            },
            reservation: %{budget_id: budget_id, cap: 4},
            grant: Arca.Test.Actor.grant(actor.athanor_id),
            verify: &Arca.Test.Actor.admits/1
          )

        {:ok, started} =
          TurnStorage.start(actor, turn.id, %{
            root_execution_id: root_id,
            attempt: attempt.attempt,
            budget_id: budget_id,
            recovery_limit: 3,
            fence: turn.fence
          })

        {started, attempt.attempt}
      end)

    log =
      capture_log(fn ->
        blocker = hold_attempt(attempt)

        {finish, finish_backend} =
          waiting(:finish, fn ->
            TurnStorage.finish(actor, turn.id, "cancelled", %{
              grant: :stored,
              verify: &Arca.Test.Actor.admits/1,
              fence: turn.fence
            })
          end)

        Arca.Test.LockWait.await_lock_wait!(finish_backend, ["execution_attempts"])

        {lapse, lapse_backend} =
          waiting(:lapse, fn ->
            Arca.Execution.mark_failed_if_running(
              root_id,
              %{@ended | completed_at: DateTime.utc_now()},
              lapse_opts(attempt)
            )
          end)

        Arca.Test.LockWait.await_lock_wait!(lapse_backend, [])
        release(blocker)

        # The turn's end took its root first, so the lapse finds it ended.
        assert {:ok, %{status: "cancelled"}} = Task.await(finish, 10_000)
        assert {0, nil} = Task.await(lapse, 10_000)
      end)

    refute log =~ "deadlock", log
    assert %Execution{status: "cancelled"} = unboxed(fn -> Arca.Repo.get!(Execution, root_id) end)
  end

  # A member's turn running in its child thread of a fresh room.
  defp running_child_turn!(actor) do
    budget_id = "bgt_lock_order_#{System.unique_integer([:positive])}"
    root_id = "exec_lock_order_child_#{System.unique_integer([:positive])}"

    {room, child, turn} =
      unboxed(fn ->
        {:ok, room} = Threads.create(actor)
        {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

        {:ok, %{turn: turn}} =
          TurnStorage.accept_message(actor, child.id, %{
            message: %{author: actor.user_id, sent_by: "person", content: "go"},
            turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
          })

        {room, child, turn}
      end)

    on_exit(fn ->
      unboxed(fn ->
        for thread <- [child, room], do: delete_thread!(actor.athanor_id, thread.id)
        delete_run!(root_id)
      end)
    end)

    unboxed(fn ->
      {:ok, %{attempt: attempt}} =
        Arca.Execution.admit(
          %{
            id: root_id,
            reference: "agent:local.planner",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "agent",
            kind: "turn",
            turn_id: turn.id,
            origin: :interactive
          },
          reservation: %{budget_id: budget_id, cap: 4},
          grant: Arca.Test.Actor.grant(actor.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )

      {:ok, started} =
        TurnStorage.start(actor, turn.id, %{
          root_execution_id: root_id,
          attempt: attempt.attempt,
          budget_id: budget_id,
          recovery_limit: 3,
          fence: turn.fence
        })

      %{room: room, child: child, turn: started, attempt: attempt.attempt}
    end)
  end

  @stored %{grant: :stored, verify: &Arca.Test.Actor.admits/1}

  test "an archive and the end of a turn it would cancel take the turn first and never deadlock" do
    actor = Arca.Test.Actor.local()
    %{child: child, turn: turn, attempt: attempt} = running_child_turn!(actor)

    log =
      capture_log(fn ->
        blocker = hold_attempt(attempt)

        # The end holds its turn and waits on the root.
        {finish, finish_backend} =
          waiting(:finish, fn ->
            TurnStorage.finish(actor, turn.id, "completed", Map.put(@stored, :fence, turn.fence))
          end)

        Arca.Test.LockWait.await_lock_wait!(finish_backend, ["execution_attempts"])

        {archive, archive_backend} =
          waiting(:archive, fn -> Threads.archive(actor, child.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(archive_backend, ["turns"])
        release(blocker)

        # The end took the turn first, so the archive finds it ended.
        assert {:ok, %{status: "completed"}} = Task.await(finish, 10_000)

        assert {:ok, %{thread: %{archived_at: %DateTime{}}, cancelled: []}} =
                 Task.await(archive, 10_000)
      end)

    refute log =~ "deadlock", log
  end

  test "a child made while its room is deleted waits for the deletion and finds no room" do
    actor = Arca.Test.Actor.local()
    %{room: room, turn: turn, attempt: attempt} = running_child_turn!(actor)
    turn_id = turn.id

    log =
      capture_log(fn ->
        blocker = hold_attempt(attempt)

        # The deletion holds the athanor and waits on the child turn's root.
        {deletion, deletion_backend} =
          waiting(:deletion, fn -> Threads.delete(actor, room.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(deletion_backend, ["execution_attempts"])

        {creation, creation_backend} =
          waiting(:creation, fn -> Threads.crew_thread(actor, room.id, "builder") end)

        Arca.Test.LockWait.await_lock_wait!(creation_backend, ["athanors"])
        release(blocker)

        assert {:ok, %{cancelled: [%{turn_id: ^turn_id}]}} = Task.await(deletion, 10_000)
        assert {:error, :not_found} = Task.await(creation, 10_000)
      end)

    refute log =~ "deadlock", log
    assert unboxed(fn -> Threads.children(actor, room.id) end) == []
  end
end
