# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionLockOrderTest do
  @moduledoc """
  Every execution write takes the execution row before any attempt row,
  so two writes of one run wait on each other in one order and never
  deadlock: a lapse of a run against the run's own terminal write, and a
  lapse of a turn's root against the turn's end. A turn's writers take
  the turn before its thread, a retirement of the thread among them, and a
  room's deletion holds the athanor's lock a child's creation waits on.
  Turns, then the athanor's row, then thread rows
  (`Arca.ThreadStorage.lock_threads!/2` states the order): a write that
  takes more than one thread row takes the athanor's row before them,
  retention and a report landing on its daily thread among them; the
  standing check reads the athanor's row after a turn, so an opening
  takes its asking turn first and a deletion the turns it stops; a step
  write, which takes no second thread row, takes no athanor lock. A write
  that takes more than one turn takes them by when each was accepted,
  then by id (`Arca.TurnStorage.hold_turns!/2`), a retirement and a
  deletion alike.
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

  # The thread `id` held by a transaction of its own until it is released.
  defp hold_thread(id) do
    test = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(c in Thread, where: c.id == ^id)
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

  # The turn `id` held by a transaction of its own until it is released.
  defp hold_turn(id) do
    test = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(t in Turn, where: t.id == ^id)
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

  # A turn of the member's in `thread`, accepted and never run.
  defp accepted!(actor, thread) do
    unboxed(fn ->
      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go"},
          turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
        })

      turn
    end)
  end

  # An athanor no other case names, its row committed, whose rows go with
  # it when the case ends: the athanor's row lock is the one in question.
  defp committed_athanor! do
    athanor_id = "ath_lock_order_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: athanor_id)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.Test.TenantTables.delete_all_for(actor)
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id))
      end)
    end)

    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor_id) end)
    actor
  end

  # An opening of a workspace thread from `daily`.
  defp opening(actor, daily, attrs) do
    Map.merge(
      %{
        daily_id: daily.id,
        id: Prima.UUID7.generate_id("thread"),
        title: "Moon report",
        opened_from: "msg_ask",
        opening: %{
          id: Prima.UUID7.generate_id("msg"),
          author: actor.user_id,
          content: "write the moon report",
          payload: %{}
        },
        pointer: %{author: "aqua", sent_by: "aqua", content: "Moon report", payload: %{}},
        files: fn _thread, _message -> {:ok, []} end,
        person_id: actor.user_id,
        origin: :interactive
      },
      attrs
    )
  end

  # A running turn of `agent` in `thread`, its root admitted and started,
  # committed in an athanor whose rows go with it (`committed_athanor!/0`).
  defp running!(actor, thread, agent) do
    unboxed(fn ->
      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go"},
          turn: %{agent: agent, requested_by: actor.user_id, origin: :interactive}
        })

      root_id = "exec_lock_order_#{System.unique_integer([:positive])}"
      budget_id = "bgt_lock_order_#{System.unique_integer([:positive])}"

      {:ok, %{attempt: attempt}} =
        Arca.Execution.admit(
          %{
            id: root_id,
            reference: "agent:local.#{agent}",
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

      started
    end)
  end

  # The standing check a write runs (`attrs[:verify]`), paused: it tells
  # the test that made it (the calling process) it is about to read the
  # athanor's row, and once let go reads it shared, as the identity
  # domain's check does (`Arca.Test.Actor.verify/1`).
  defp paused_verify do
    test = self()

    fn grant ->
      send(test, {:verifying, self()})

      receive do
        :verify -> Arca.Test.Actor.verify(grant)
      after
        10_000 -> {:error, :unavailable}
      end
    end
  end

  # The athanor's row held shared by a transaction of its own, as a
  # standing check holds it, until it is released.
  defp hold_standing(athanor_id) do
    test = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            {:ok, %{}} =
              Arca.ExecutionStanding.locked(Prima.Actor.in_athanor(athanor_id), athanor_id)

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
        {:ok, thread} = Arca.Test.Days.thread(actor)

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
        {:ok, room} = Arca.Test.Days.thread(actor)
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

  test "a retirement and the end of a turn it would cancel take the turn first and never deadlock" do
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

        {retire, retire_backend} =
          waiting(:retire, fn -> Threads.retire(actor, child.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(retire_backend, ["turns"])
        release(blocker)

        # The end took the turn first, so the retirement finds it ended.
        assert {:ok, %{status: "completed"}} = Task.await(finish, 10_000)

        assert {:ok, %{thread: %{retired_at: %DateTime{}}, cancelled: []}} =
                 Task.await(retire, 10_000)
      end)

    refute log =~ "deadlock", log
  end

  test "retention and a report landing on its daily thread take the athanor first and never deadlock" do
    actor = committed_athanor!()

    {daily, workspace} =
      unboxed(fn ->
        {:ok, daily} = Arca.Test.Days.thread(actor)

        {:ok, %{workspace: workspace}} =
          TurnStorage.open_workspace(actor, opening(actor, daily, %{}))

        # Finished, its opening stopped before it started, so no work
        # remains and both are retention's to archive.
        {1, _} =
          Arca.Repo.update_all(from(c in Thread, where: c.id == ^workspace.id),
            set: [workspace_state: "done", workspace_outcome: "done"]
          )

        {1, _} =
          Arca.Repo.update_all(
            from(m in Message, where: m.thread_id == ^workspace.id and m.kind == "opening"),
            set: [status: "expired"]
          )

        {daily, workspace}
      end)

    # The daily thread's id first, as retention takes its candidates.
    assert daily.id < workspace.id
    cutoff = DateTime.add(DateTime.utc_now(), 3600)

    report = %{
      author: "aqua",
      sent_by: "aqua",
      kind: "report",
      workspace_id: workspace.id,
      content: "Done."
    }

    log =
      capture_log(fn ->
        blocker = hold_thread(daily.id)

        # Retention holds the athanor and waits on the daily thread.
        {retention, retention_backend} =
          waiting(:retention, fn -> Threads.archive_idle(actor, cutoff) end)

        Arca.Test.LockWait.await_lock_wait!(retention_backend, ["threads"])

        {landing, landing_backend} =
          waiting(:landing, fn ->
            TurnStorage.accept_message(actor, daily.id, %{message: report})
          end)

        Arca.Test.LockWait.await_lock_wait!(landing_backend, ["athanors"])
        release(blocker)

        # Retention went first and archived both; the report, which starts
        # no work, lands on the archived daily thread after it.
        assert {:ok, 2} = Task.await(retention, 10_000)
        assert {:ok, %{message: %{kind: "report"}, turn: nil}} = Task.await(landing, 10_000)
      end)

    refute log =~ "deadlock", log
    assert {:ok, %{archived_at: %DateTime{}}} = unboxed(fn -> Threads.get(actor, daily.id) end)

    assert {:ok, %{archived_at: %DateTime{}}} =
             unboxed(fn -> Threads.get(actor, workspace.id) end)
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

  test "an opening takes its asking turn before the athanor's row, so a takeover of that turn never deadlocks it" do
    actor = committed_athanor!()
    {:ok, daily} = unboxed(fn -> Arca.Test.Days.thread(actor) end)
    turn = running!(actor, daily, "aqua")

    verify = paused_verify()

    log =
      capture_log(fn ->
        # The takeover holds the turn and is about to read the standing.
        {takeover, _backend} =
          waiting(:takeover, fn ->
            TurnStorage.takeover(actor, turn.id, %{
              fence: turn.fence,
              grant: :stored,
              verify: verify
            })
          end)

        assert_receive {:verifying, verifier}, 5_000

        {opening, opening_backend} =
          waiting(:opening, fn ->
            TurnStorage.open_workspace(
              actor,
              opening(actor, daily, %{turn: %{id: turn.id, fence: turn.fence}})
            )
          end)

        Arca.Test.LockWait.await_lock_wait!(opening_backend, ["turns"])
        send(verifier, :verify)

        # The takeover moved the fence, so the opening it held off finds
        # its turn superseded.
        assert {:ok, %{fence: fence}} = Task.await(takeover, 10_000)
        assert fence == turn.fence + 1
        assert {:error, :superseded} = Task.await(opening, 10_000)
      end)

    refute log =~ "deadlock", log
  end

  test "a step write in a crew member's thread under a workspace thread takes no lock on the athanor's row" do
    actor = committed_athanor!()
    {:ok, daily} = unboxed(fn -> Arca.Test.Days.thread(actor) end)

    {:ok, %{workspace: workspace}} =
      unboxed(fn -> TurnStorage.open_workspace(actor, opening(actor, daily, %{})) end)

    {:ok, child} = unboxed(fn -> Threads.crew_thread(actor, workspace.id, "planner") end)
    turn = running!(actor, child, "planner")
    standing = hold_standing(actor.athanor_id)

    step =
      Task.async(fn ->
        unboxed(fn ->
          TurnStorage.put_step(actor, turn.id, %{
            kind: "model",
            idempotency_key: "model:lock-order",
            fence: turn.fence
          })
        end)
      end)

    # It lands while the athanor's row is held, so it never asked for it.
    assert {:ok, {:ok, %{kind: "model"}}} = Task.yield(step, 5_000)
    release(standing)
  end

  test "a deletion takes the turns it stops before the athanor's row, so a completion's standing check never deadlocks it" do
    actor = committed_athanor!()
    {:ok, room} = unboxed(fn -> Arca.Test.Days.thread(actor) end)
    {:ok, child} = unboxed(fn -> Threads.crew_thread(actor, room.id, "planner") end)
    turn = running!(actor, child, "planner")

    verify = paused_verify()

    log =
      capture_log(fn ->
        # The completion holds the child's turn and is about to read the
        # standing.
        {completion, _backend} =
          waiting(:completion, fn ->
            TurnStorage.finish(actor, turn.id, "completed", %{
              fence: turn.fence,
              grant: :stored,
              verify: verify
            })
          end)

        assert_receive {:verifying, verifier}, 5_000

        {deletion, deletion_backend} =
          waiting(:deletion, fn -> Threads.delete(actor, room.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(deletion_backend, ["turns"])
        send(verifier, :verify)

        # The deletion waited on the turn without the athanor's row, so
        # the completion read its standing and ended the turn first.
        assert {:ok, %{status: "completed"}} = Task.await(completion, 10_000)
        assert {:ok, %{cancelled: []}} = Task.await(deletion, 10_000)
      end)

    refute log =~ "deadlock", log
    assert {:error, :not_found} = unboxed(fn -> Threads.get(actor, room.id) end)
  end

  test "a retirement and a deletion take a crew thread's turns in one order, by when each was accepted" do
    actor = committed_athanor!()
    {:ok, room} = unboxed(fn -> Arca.Test.Days.thread(actor) end)
    {:ok, child} = unboxed(fn -> Threads.crew_thread(actor, room.id, "planner") end)
    [lower, higher] = Enum.sort_by([accepted!(actor, child), accepted!(actor, child)], & &1.id)

    # The lower id accepted later: by id and by acceptance the two turns
    # stand in opposite orders.
    unboxed(fn ->
      {1, _} =
        Arca.Repo.update_all(from(t in Turn, where: t.id == ^lower.id),
          set: [accepted_at: DateTime.add(higher.accepted_at, 1, :second)]
        )
    end)

    log =
      capture_log(fn ->
        blocker = hold_turn(higher.id)

        # The retirement waits on the earlier-accepted turn, holding none.
        {retire, retire_backend} =
          waiting(:retire, fn -> Threads.retire(actor, child.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(retire_backend, ["turns"])

        {deletion, deletion_backend} =
          waiting(:deletion, fn -> Threads.delete(actor, room.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(deletion_backend, ["turns"])
        release(blocker)

        # Both took the earlier-accepted turn first, so the retirement went
        # first with both and the deletion followed with nothing to cancel.
        assert {:ok, %{thread: %{retired_at: %DateTime{}}, cancelled: cancelled}} =
                 Task.await(retire, 10_000)

        assert length(cancelled) == 2
        assert {:ok, %{cancelled: []}} = Task.await(deletion, 10_000)
      end)

    refute log =~ "deadlock", log
  end

  # A room with a crew member's thread holding one accepted turn, that
  # turn held by a third transaction.
  defp member_turn_held! do
    actor = committed_athanor!()
    {:ok, room} = unboxed(fn -> Arca.Test.Days.thread(actor) end)
    {:ok, child} = unboxed(fn -> Threads.crew_thread(actor, room.id, "planner") end)
    turn = accepted!(actor, child)
    %{actor: actor, room: room, child: child, turn: turn, blocker: hold_turn(turn.id)}
  end

  test "a retirement that a deletion of its room goes before finds no thread, and writes nothing" do
    %{actor: actor, room: room, child: child, turn: turn, blocker: blocker} = member_turn_held!()
    turn_id = turn.id

    log =
      capture_log(fn ->
        {deletion, deletion_backend} =
          waiting(:deletion, fn -> Threads.delete(actor, room.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(deletion_backend, ["turns"])

        {retire, retire_backend} =
          waiting(:retire, fn -> Threads.retire(actor, child.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(retire_backend, ["turns"])
        release(blocker)

        assert {:ok, %{cancelled: [%{turn_id: ^turn_id}]}} = Task.await(deletion, 10_000)
        assert {:error, :not_found} = Task.await(retire, 10_000)
      end)

    refute log =~ "MatchError", log
    assert {:error, :not_found} = unboxed(fn -> Threads.get(actor, child.id) end)
  end

  test "a deletion that a retirement of its member's thread goes before removes the retired thread" do
    %{actor: actor, room: room, child: child, turn: turn, blocker: blocker} = member_turn_held!()
    turn_id = turn.id

    log =
      capture_log(fn ->
        {retire, retire_backend} =
          waiting(:retire, fn -> Threads.retire(actor, child.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(retire_backend, ["turns"])

        {deletion, deletion_backend} =
          waiting(:deletion, fn -> Threads.delete(actor, room.id, @stored) end)

        Arca.Test.LockWait.await_lock_wait!(deletion_backend, ["turns"])
        release(blocker)

        assert {:ok, %{thread: %{retired_at: %DateTime{}}, cancelled: [%{turn_id: ^turn_id}]}} =
                 Task.await(retire, 10_000)

        assert {:ok, %{cancelled: []}} = Task.await(deletion, 10_000)
      end)

    refute log =~ "deadlock", log
    assert {:error, :not_found} = unboxed(fn -> Threads.get(actor, child.id) end)
    assert {:error, :not_found} = unboxed(fn -> Threads.get(actor, room.id) end)
  end
end
