# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadArchiveTest do
  @moduledoc """
  The archive of a daily or a workspace thread (`Arca.ThreadStorage`'s
  "Archive"): by the person or by the setting, never while work remains
  in it or in a crew thread under it; an ordinary thread behind a filter
  that new work takes out again, each write that starts work placed
  before and after the archive at its owner, and on PostgreSQL held just
  after its clear while an archive asks for the same thread; and the
  setting that replaced deletion by age.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, daily} = Arca.Test.Days.thread(actor)
    {:ok, actor: actor, daily: daily}
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp open!(actor, daily, attrs \\ %{}) do
    {:ok, %{workspace: workspace}} =
      TurnStorage.open_workspace(actor, opening(actor, daily, attrs))

    workspace
  end

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
          payload: %{"ask" => "write the moon report"}
        },
        pointer: %{author: "aqua", sent_by: "aqua", content: "Moon report", payload: %{}},
        files: fn _thread, _message -> {:ok, []} end,
        person_id: actor.user_id,
        origin: :interactive
      },
      attrs
    )
  end

  # A workspace thread whose work ended: its openings no longer wait and
  # it reads finished.
  defp finished!(workspace) do
    from(m in Arca.Schemas.Message, where: m.thread_id == ^workspace.id and m.kind == "opening")
    |> Arca.Repo.update_all(set: [status: "expired"])

    from(c in Arca.Schemas.Thread, where: c.id == ^workspace.id)
    |> Arca.Repo.update_all(set: [workspace_state: "done", workspace_outcome: "done"])

    workspace
  end

  # The threads' activity and creation moved `days` back.
  defp aged!(ids, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(c in Arca.Schemas.Thread, where: c.id in ^ids)
    |> Arca.Repo.update_all(set: [last_message_at: at, inserted_at: at])
  end

  defp post(actor, thread, attrs \\ %{}) do
    TurnStorage.accept_message(
      actor,
      thread.id,
      Map.merge(
        %{
          message: %{author: actor.user_id, sent_by: "person", content: "one more thing"},
          turn: %{
            agent: thread.agent || "aqua",
            requested_by: actor.user_id,
            origin: :interactive
          }
        },
        attrs
      )
    )
  end

  # A running turn of `thread`, with its root.
  defp running!(actor, thread) do
    {:ok, %{turn: turn}} = post(actor, thread)
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
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
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        budget_id: budget_id,
        recovery_limit: 3,
        fence: turn.fence
      })

    started
  end

  # A card in `turn`, as the loop opens one.
  defp card!(actor, turn, key) do
    {:ok, model} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "model",
        idempotency_key: "model:#{key}",
        fence: turn.fence
      })

    {:ok, %{calls: [%{step: call}]}} =
      TurnStorage.record_response(actor, turn.id, model.id, %{
        fence: turn.fence,
        text: nil,
        usage: %{},
        stop_reason: "tool_call",
        tool_calls: [
          %{
            tool_call_id: key,
            name: "notes",
            tool: "notes",
            action: "keep",
            arguments: %{},
            kind: "write",
            idempotency_key: "call:#{key}",
            proposal_digest: "sha256:#{key}"
          }
        ]
      })

    {:ok, %{approval: approval}} =
      TurnStorage.open_approval(actor, call.id, %{
        proposal_digest: "sha256:#{key}",
        card: %{content: "Keep the note?"},
        fence: turn.fence
      })

    approval
  end

  defp decline!(actor, turn, approval) do
    {:ok, _} =
      TurnStorage.resolve_approval(actor, approval.id, "declined", %{
        fence: turn.fence,
        resolution_kind: Prima.TurnState.resolution_kind("declined", "tool"),
        denied_result: %{content: "declined", payload: %{}}
      })
  end

  # A workspace thread that needs its person for one card and has no
  # other work: its opening no longer waits, and its one turn waits on the
  # card.
  defp needs_you!(actor, daily) do
    workspace = open!(actor, daily)

    from(m in Arca.Schemas.Message, where: m.thread_id == ^workspace.id and m.kind == "opening")
    |> Arca.Repo.update_all(set: [status: "expired"])

    turn = running!(actor, workspace)
    approval = card!(actor, turn, "keep-#{System.unique_integer([:positive])}")
    {workspace, turn, approval}
  end

  defp archived?(actor, id), do: Threads.archived?(elem(Threads.get(actor, id), 1))

  defp job(actor), do: %{Prima.Actor.system() | athanor_id: actor.athanor_id, scope: :athanor}

  defp cutoff(days \\ 3), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # ---------------------------------------------------------------------------
  # By the person

  test "a finished workspace thread is archived behind the filter, and nothing else about it changes",
       %{actor: actor, daily: daily} do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, before} = Threads.get(actor, workspace.id)

    assert {:ok, archived} = Threads.archive(actor, workspace.id)
    assert Threads.archived?(archived)

    {:ok, read} = Threads.get(actor, workspace.id)

    assert Map.drop(read, [:archived_at, :updated_at]) ==
             Map.drop(before, [:archived_at, :updated_at])

    assert Enum.map(Threads.list(actor, archived: true), & &1.id) == [workspace.id]
    refute workspace.id in Enum.map(Threads.list(actor, archived: false), & &1.id)
    assert workspace.id in Enum.map(Threads.list(actor), & &1.id)

    # Still readable and found by Aqua's search.
    assert [%{kind: "opening"}] = Threads.messages(actor, workspace.id, posts: true)
    {:ok, %{posts: posts}} = Threads.search(actor, "moon report")
    assert Enum.any?(posts, &(&1.thread.id == workspace.id))

    # Archived again, it answers as it stands.
    assert {:ok, again} = Threads.archive(actor, workspace.id)
    assert again.archived_at == read.archived_at
  end

  test "a thread is not archived while work remains in it or in a crew thread under it, whatever it reads",
       %{actor: actor, daily: daily} do
    # Working: its opening waits for its turn.
    working = open!(actor, daily)
    assert {:error, :working} = Threads.archive(actor, working.id)

    # A daily thread with a turn of Aqua's running.
    _running = running!(actor, daily)
    assert {:error, :working} = Threads.archive(actor, daily.id)

    # Needs you for a card while a crew member still works.
    {waiting, _turn, _approval} = needs_you!(actor, daily)
    assert {:ok, %{workspace_state: "needs_you"}} = Threads.get(actor, waiting.id)
    {:ok, child} = Threads.crew_thread(actor, waiting.id, "planner")
    _crew = running!(actor, child)
    assert {:error, :working} = Threads.archive(actor, waiting.id)
    refute archived?(actor, waiting.id)

    # A crew member's thread is retired, never archived.
    assert {:error, :not_a_room} = Threads.archive(actor, child.id)
  end

  test "a thread that needs its person for a card and has no other work is archived, and the card still waits",
       %{actor: actor, daily: daily} do
    {workspace, _turn, approval} = needs_you!(actor, daily)

    assert {:ok, _} = Threads.archive(actor, workspace.id)
    assert {:ok, %{workspace_state: "needs_you"}} = Threads.get(actor, workspace.id)
    assert [%{id: id}] = Threads.pending_approvals(actor, workspace.id)
    assert id == approval.message_id
  end

  # ---------------------------------------------------------------------------
  # New work, placed after the archive and before it

  test "a person's post after the archive takes the thread out; one before it keeps it from being archived",
       %{actor: actor, daily: daily} do
    after_it = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, _} = Threads.archive(actor, after_it.id)
    assert {:ok, %{turn: %{}}} = post(actor, after_it)
    refute archived?(actor, after_it.id)

    before_it = daily |> then(&open!(actor, &1)) |> finished!()
    assert {:ok, %{turn: %{}}} = post(actor, before_it)
    assert {:error, :working} = Threads.archive(actor, before_it.id)
  end

  test "a further opening after the archive takes the workspace thread out", %{
    actor: actor,
    daily: daily
  } do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, _} = Threads.archive(actor, workspace.id)

    assert {:ok, _} =
             TurnStorage.open_workspace(
               actor,
               opening(actor, daily, %{workspace_id: workspace.id})
             )

    refute archived?(actor, workspace.id)
    assert {:error, :working} = Threads.archive(actor, workspace.id)
  end

  test "new work in a crew member's thread takes its room out of the archive", %{
    actor: actor,
    daily: daily
  } do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
    {:ok, _} = Threads.archive(actor, workspace.id)

    assert {:ok, %{turn: %{}}} = post(actor, child)
    refute archived?(actor, workspace.id)
  end

  test "deciding a card resumes its turn and takes its thread out of the archive at once, the crew's room among them",
       %{actor: actor, daily: daily} do
    {workspace, turn, approval} = needs_you!(actor, daily)
    {:ok, _} = Threads.archive(actor, workspace.id)
    decline!(actor, turn, approval)
    refute archived?(actor, workspace.id)

    # A crew member's card under a room with no other work: its decision
    # takes the room out.
    room = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
    crew_turn = running!(actor, child)
    crew_card = card!(actor, crew_turn, "crew-keep")
    {:ok, _} = Threads.archive(actor, room.id)
    decline!(actor, crew_turn, crew_card)
    refute archived?(actor, room.id)
  end

  test "a page's call in a crew member's thread is no work: the room is archived by hand and by the setting",
       %{actor: actor, daily: daily} do
    page_call = %{
      message: %{author: "aqua", sent_by: "aqua", kind: "page_call", content: "invoke"}
    }

    [by_hand, by_setting] =
      for _ <- 1..2 do
        room = daily |> then(&open!(actor, &1)) |> finished!()
        {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
        assert {:ok, %{turn: %{}}} = post(actor, child, page_call)
        room
      end

    assert {:ok, %{archived_at: %DateTime{}}} = Threads.archive(actor, by_hand.id)
    assert {:ok, _} = Threads.archive_idle(actor, DateTime.add(DateTime.utc_now(), 3600))
    assert archived?(actor, by_setting.id)
  end

  test "a page's call and a row that starts no work leave the thread archived", %{
    actor: actor,
    daily: daily
  } do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, _} = Threads.archive(actor, workspace.id)

    assert {:ok, %{turn: %{}}} =
             post(actor, workspace, %{
               message: %{author: "aqua", sent_by: "aqua", kind: "page_call", content: "invoke"}
             })

    assert archived?(actor, workspace.id)

    assert {:ok, %{turn: nil}} =
             TurnStorage.accept_message(actor, workspace.id, %{
               message: %{author: "aqua", sent_by: "aqua", content: "a row of Aqua's"}
             })

    assert archived?(actor, workspace.id)
  end

  # ---------------------------------------------------------------------------
  # By the setting

  test "the setting archives a thread with no activity in it or in its crew threads, and the dry run counts it first",
       %{actor: actor, daily: daily} do
    idle = daily |> then(&open!(actor, &1)) |> finished!()
    crew_busy = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, child} = Threads.crew_thread(actor, crew_busy.id, "planner")
    aged!([daily.id, idle.id, crew_busy.id], 10)

    assert {:ok, 2} = Threads.count_idle(actor, cutoff())
    assert {:ok, 2} = Arca.Retention.cleanup(actor, "archive_days", dry_run: true)
    refute archived?(actor, idle.id)

    assert {:ok, 2} = Arca.Retention.cleanup(actor, "archive_days")
    assert archived?(actor, idle.id)
    assert archived?(actor, daily.id)
    refute archived?(actor, crew_busy.id), "its crew thread was active within the days"

    # Once its crew thread is as old, it goes too, and the crew thread is
    # untouched.
    aged!([child.id], 10)
    assert {:ok, 1} = Threads.archive_idle(actor, cutoff())
    assert archived?(actor, crew_busy.id)
    assert {:ok, %{retired_at: nil, archived_at: nil}} = Threads.get(actor, child.id)

    # A further run finds nothing left.
    assert {:ok, 0} = Threads.count_idle(actor, cutoff())
  end

  test "the setting never archives a thread in which work remains, however old", %{
    actor: actor,
    daily: daily
  } do
    working = open!(actor, daily)
    {waiting, _turn, _approval} = needs_you!(actor, daily)
    {:ok, child} = Threads.crew_thread(actor, waiting.id, "planner")
    _crew = running!(actor, child)
    aged!([working.id, waiting.id, child.id], 10)

    assert {:ok, 0} = Threads.archive_idle(actor, cutoff())
    refute archived?(actor, working.id)
    refute archived?(actor, waiting.id)
  end

  test "deletion by age is gone: a room past any age and the crew thread under it both stand", %{
    actor: actor,
    daily: daily
  } do
    room = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
    aged!([daily.id, room.id, child.id], 4000)

    {:ok, %{deleted: deleted}} = Arca.Retention.cleanup_athanor(job(actor))
    assert deleted["archive_days"] == 2
    refute Map.has_key?(deleted, "messages_days")

    assert {:ok, %{archived_at: %DateTime{}}} = Threads.get(actor, room.id)
    assert {:ok, %{kind: "crew", parent_id: parent}} = Threads.get(actor, child.id)
    assert parent == room.id
  end

  test "new work after the setting archived a thread takes it out; the setting's next run before new work keeps it",
       %{actor: actor, daily: daily} do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    aged!([workspace.id], 10)
    assert {:ok, n} = Threads.archive_idle(actor, cutoff())
    assert n >= 1
    assert archived?(actor, workspace.id)

    # The person archived nothing more by hand, and a further run leaves it.
    assert {:ok, _} = Threads.archive(actor, workspace.id)
    assert {:ok, 0} = Threads.archive_idle(actor, cutoff())
    assert archived?(actor, workspace.id)

    assert {:ok, %{turn: %{}}} = post(actor, workspace)
    refute archived?(actor, workspace.id)
    assert {:ok, 0} = Threads.archive_idle(actor, cutoff())
    refute archived?(actor, workspace.id)
  end

  test "zero turns the setting off, and only for archive_days; other values are refused", %{
    actor: actor,
    daily: daily
  } do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    aged!([daily.id, workspace.id], 10)

    assert {:ok, %{"archive_days" => 3}} = Arca.Retention.get_settings(actor)

    assert {:ok, %{"archive_days" => 0}} =
             Arca.Retention.set_settings(actor, %{"archive_days" => 0})

    assert {:ok, 0} = Arca.Retention.cleanup(actor, "archive_days")
    refute archived?(actor, workspace.id)

    for value <- [-1, 1.5, "3", nil] do
      assert {:error, {:invalid_setting, "archive_days"}} =
               Arca.Retention.set_settings(actor, %{"archive_days" => value})
    end

    assert {:error, {:invalid_setting, "mcp_log_days"}} =
             Arca.Retention.set_settings(actor, %{"mcp_log_days" => 0})

    assert {:error, {:unknown_setting, "messages_days"}} =
             Arca.Retention.set_settings(actor, %{"messages_days" => 30})
  end

  test "the retention tool says archived and would_archive for archive_days, deleted for any other key",
       %{actor: actor, daily: daily} do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()
    aged!([daily.id, workspace.id], 10)
    cleanup = %{"action" => "cleanup", "cleanup_type" => "archive_days"}

    assert {:ok, %{would_archive: 2, dry_run: true} = dry} =
             Arca.Providers.Records.handle("retention", actor, Map.put(cleanup, "dry_run", true))

    refute Map.has_key?(dry, :would_delete)

    assert {:ok, %{archived: 2} = done} =
             Arca.Providers.Records.handle("retention", actor, cleanup)

    refute Map.has_key?(done, :deleted)

    assert {:ok, %{deleted: _}} =
             Arca.Providers.Records.handle("retention", actor, %{
               "action" => "cleanup",
               "cleanup_type" => "mcp_log_days"
             })

    assert {:error, {:invalid_argument, sentence}} =
             Arca.Providers.Records.handle("retention", actor, %{
               "action" => "set",
               "settings" => %{"archive_days" => -1}
             })

    assert sentence =~ "0 to archive nothing"
  end

  test "each archive is announced after its commit, by the person or by the setting", %{
    actor: actor,
    daily: daily
  } do
    me = self()
    handler = "thread-archived-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :arca, :thread, :archived],
        fn _event, _measure, meta, _config -> send(me, {:archived, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    by_hand = daily |> then(&open!(actor, &1)) |> finished!()
    {:ok, _} = Threads.archive(actor, by_hand.id)
    assert_received {:archived, %{thread_id: id, athanor_id: athanor}}
    assert id == by_hand.id and athanor == actor.athanor_id

    # Archived again, nothing moved and nothing is told.
    {:ok, _} = Threads.archive(actor, by_hand.id)
    refute_received {:archived, _}

    by_setting = daily |> then(&open!(actor, &1)) |> finished!()
    aged!([by_setting.id], 10)
    {:ok, 1} = Threads.archive_idle(actor, cutoff())
    assert_received {:archived, %{thread_id: id}}
    assert id == by_setting.id
  end

  # ---------------------------------------------------------------------------
  # New work and an archive at once (PostgreSQL)
  #
  # Each write that starts new work is held just after its clear, inside
  # its transaction, while the person's archive or the setting's asks for
  # the same thread: the archive waits on a lock the write holds, the
  # thread's row (or the athanor's, which a write that takes two thread
  # rows holds before them), and once the write commits it finds the work
  # and leaves the thread as it is. On committed rows and connections of
  # their own, so a deadlock would abort one of them.

  @writes [
    post: "a person's post in the thread",
    crew_post: "a post in a crew member's thread under it",
    opening: "a further opening of the workspace thread",
    decision: "a decision in the daily thread",
    workspace_decision: "a decision in the workspace thread",
    crew_decision: "a decision in a crew member's thread under it"
  ]

  for {write, words} <- @writes,
      {archive, by} <- [hand: "the person's", setting: "the setting's"] do
    @tag :postgres
    test "new work held after its clear, #{words}, against #{by} archive: the archive waits, " <>
           "then finds the work" do
      raced!(unquote(write), unquote(archive))
    end
  end

  defp raced!(write, archive) do
    athanor = "ath_archive_race_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: athanor)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.Test.TenantTables.delete_all_for(actor)
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
      end)
    end)

    {thread, writes} =
      unboxed(fn ->
        Arca.Test.Actor.ensure_athanor_row(athanor)
        {:ok, daily} = Arca.Test.Days.thread(actor)
        racing(write, actor, daily)
      end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        held = held_after_clear!(writes)

        {archiving, backend} =
          waiting(fn ->
            case archive do
              :hand -> Threads.archive(actor, thread.id)
              :setting -> Threads.archive_idle(actor, DateTime.add(DateTime.utc_now(), 3600))
            end
          end)

        Arca.Test.LockWait.await_lock_wait!(backend)
        send(held.pid, :go)
        assert {:ok, _} = Task.await(held, 15_000)

        case archive do
          :hand -> assert {:error, :working} = Task.await(archiving, 15_000)
          :setting -> assert {:ok, _} = Task.await(archiving, 15_000)
        end
      end)

    refute log =~ "deadlock", log
    refute unboxed(fn -> archived?(actor, thread.id) end), "resumed work was left archived"
  end

  # The thread an archive asks for, and the write that starts new work in
  # it or in a crew member's thread under it, which finds no work there
  # yet.
  defp racing(:post, actor, daily), do: {daily, fn -> post(actor, daily) end}

  defp racing(:crew_post, actor, daily) do
    {:ok, crew} = Threads.crew_thread(actor, daily.id, "planner")
    {daily, fn -> post(actor, crew) end}
  end

  defp racing(:opening, actor, daily) do
    workspace = daily |> then(&open!(actor, &1)) |> finished!()

    {workspace,
     fn ->
       TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))
     end}
  end

  defp racing(:decision, actor, daily) do
    turn = running!(actor, daily)
    card = card!(actor, turn, "race")
    {daily, fn -> decline!(actor, turn, card) end}
  end

  defp racing(:workspace_decision, actor, daily) do
    {workspace, turn, card} = needs_you!(actor, daily)
    {workspace, fn -> decline!(actor, turn, card) end}
  end

  defp racing(:crew_decision, actor, daily) do
    {:ok, crew} = Threads.crew_thread(actor, daily.id, "planner")
    turn = running!(actor, crew)
    card = card!(actor, turn, "race")
    {daily, fn -> decline!(actor, turn, card) end}
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  # `writes` on a connection of its own, held inside its transaction just
  # after the statement that clears the archive, until it is sent `:go`.
  defp held_after_clear!(writes) do
    test = self()
    handler = "archive-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if Process.get(:archive_race_writer) == true and is_binary(meta.query) and
               String.contains?(meta.query, ~s(SET "archived_at")) do
            Process.delete(:archive_race_writer)
            send(test, {:cleared, self()})

            receive do
              :go -> :ok
            after
              15_000 -> raise "the write held after its clear was never let go"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    held =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:archive_race_writer, true)
          writes.()
        end)
      end)

    on_exit(fn -> if Process.alive?(held.pid), do: Process.exit(held.pid, :kill) end)
    assert_receive {:cleared, pid}, 5_000
    assert pid == held.pid
    held
  end

  # `fun` on a connection of its own, its backend told first.
  defp waiting(fun) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(test, {:backend, backend})
          fun.()
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:backend, backend}, 5_000
    {task, backend}
  end
end
