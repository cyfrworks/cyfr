# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WorkspaceStorageTest do
  @moduledoc """
  A workspace thread's rows: opened in one transaction with its opening,
  its pointer and its record, or none of them; its state moved by the
  write that moves it; and a row that names it landing only while it
  stands.
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

  defp records(actor, kind) do
    {:ok, records} = Arca.Outbox.pending(actor, "crew_delivery", kind)
    records
  end

  defp state(actor, id), do: elem(Threads.get(actor, id), 1).workspace_state

  # A running turn of `thread`, with its root.
  defp running!(actor, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: thread.agent || "aqua", requested_by: actor.user_id, origin: :interactive}
      })

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
        agent_mode: "auto",
        recovery_limit: 3,
        fence: turn.fence
      })

    started
  end

  # The turn an opening's delivery opens on it, accepted and never run.
  defp opening_turn!(actor, workspace, opening) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, workspace.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: opening.content},
        opening_id: opening.id,
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    turn
  end

  defp finish!(actor, turn) do
    {:ok, _} =
      TurnStorage.finish(actor, turn.id, "cancelled", %{
        fence: turn.fence,
        error: "stopped",
        grant: :stored,
        verify: &Arca.Test.Actor.admits/1
      })
  end

  test "an opening commits its thread, opening, pointer and record together, or none of them",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)

    assert %{kind: "workspace", workspace_state: "open", opened_from: "msg_ask"} = workspace
    assert [%{kind: "opening", sent_by: "person"}] = Threads.messages(actor, workspace.id)
    assert [%{kind: "pointer", workspace_id: id}] = Threads.messages(actor, daily.id)
    assert id == workspace.id
    assert [%{source_kind: "thread", source_id: ^id}] = records(actor, "workspace_open")

    # A refusal after the files were stored writes no row.
    refused =
      opening(actor, daily, %{
        files: fn _thread, _message -> {:error, :storage_full} end
      })

    assert {:error, :storage_full} = TurnStorage.open_workspace(actor, refused)
    assert [_one] = Threads.list(actor, kind: "workspace")
    assert [_pointer] = Threads.messages(actor, daily.id)
    assert [_record] = records(actor, "workspace_open")

    # Only a daily thread opens one, and only an athanor's own.
    assert {:error, :not_a_daily_thread} =
             TurnStorage.open_workspace(actor, opening(actor, daily, %{daily_id: workspace.id}))

    other = Prima.Actor.in_athanor("ath_other_#{System.unique_integer([:positive])}")

    assert {:error, :not_found} = TurnStorage.open_workspace(other, opening(other, daily, %{}))
  end

  test "a deletion leaves nothing of a report, whichever comes first: one that landed goes with it, and one after it lands nothing",
       %{actor: actor, daily: daily} do
    report = fn workspace ->
      %{
        author: "aqua",
        sent_by: "aqua",
        kind: "report",
        workspace_id: workspace.id,
        content: "Done."
      }
    end

    # The report lands, then the deletion: it goes with the thread.
    first = open!(actor, daily)

    {:ok, %{message: landed}} =
      TurnStorage.accept_message(actor, daily.id, %{message: report.(first)})

    {:ok, _} = Threads.delete(actor, first.id)
    refute Enum.any?(Threads.messages(actor, daily.id), &(&1.id == landed.id))

    # The deletion, then the report: it lands nothing.
    second = open!(actor, daily)
    {:ok, _} = Threads.delete(actor, second.id)

    assert {:error, :workspace_gone} =
             TurnStorage.accept_message(actor, daily.id, %{message: report.(second)})

    refute Enum.any?(
             Threads.messages(actor, daily.id),
             &(&1.workspace_id in [first.id, second.id])
           )
  end

  test "the setting archives a thread an open turn has read all the same, and deleting it by hand waits on that turn's root grant",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)
    reader = running!(actor, daily)
    read = Prima.Source.encode([Prima.Source.thread(workspace.id)])

    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Turn, where: t.id == ^reader.id),
        set: [sources: read]
      )

    # Finished, its opening stopped before it started: no work remains in it.
    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Thread, where: c.id == ^workspace.id),
        set: [workspace_state: "done"]
      )

    {1, _} =
      Arca.Repo.update_all(
        from(m in Arca.Schemas.Message,
          where: m.thread_id == ^workspace.id and m.kind == "opening"
        ),
        set: [status: "expired"]
      )

    # The daily thread holds the open turn, so the workspace thread alone
    # is archived; that the turn read it keeps nothing.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert {:ok, 1} = Threads.count_idle(actor, future)
    assert {:ok, 1} = Threads.archive_idle(actor, future)
    assert {:ok, %{archived_at: %DateTime{}}} = Threads.get(actor, workspace.id)
    assert {:ok, %{archived_at: nil}} = Threads.get(actor, daily.id)

    # Forgetting it would stop the open turn that read it, and stopping a
    # turn with a root ends its attempt under the root's grant: a deletion
    # that names none is refused.
    assert {:error, :missing_grant} = Threads.delete(actor, workspace.id)

    # Once that turn has ended, a deletion by hand forgets the thread.
    {:ok, _} =
      TurnStorage.finish(actor, reader.id, "failed", %{
        fence: reader.fence,
        error: "stopped",
        grant: :stored,
        verify: &Arca.Test.Actor.admits/1
      })

    assert {:ok, %{cancelled: []}} = Threads.delete(actor, workspace.id)
    assert {:error, :not_found} = Threads.get(actor, workspace.id)
  end

  # Every opening accepted reports once.
  test "a report ends its own turn's work, and the thread's only when nothing else it accepted remains to run",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)

    {:ok, _again} =
      TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))

    [first, second] =
      for %{kind: "opening"} = row <- Threads.messages(actor, workspace.id), do: row

    one = opening_turn!(actor, workspace, first)

    {:ok, %{workspace_state: "open"}} =
      TurnStorage.report_workspace(actor, one.id, "done", %{
        fence: one.fence,
        summary: "First done"
      })

    assert state(actor, workspace.id) == "open"

    # The first turn reports its own work once.
    assert {:error, :reported} =
             TurnStorage.report_workspace(actor, one.id, "needs_you", %{
               fence: one.fence,
               summary: "again"
             })

    finish!(actor, one)
    two = opening_turn!(actor, workspace, second)

    {:ok, %{workspace_state: "done"}} =
      TurnStorage.report_workspace(actor, two.id, "done", %{
        fence: two.fence,
        summary: "Second done"
      })

    assert ["First done", "Second done"] =
             for(record <- records(actor, "workspace_report"), do: record.snapshot["summary"])

    assert state(actor, workspace.id) == "done"
  end

  test "a row naming a workspace thread lands only while it stands", %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)

    report = %{
      author: "aqua",
      sent_by: "aqua",
      kind: "report",
      workspace_id: workspace.id,
      content: "Done."
    }

    assert {:ok, %{message: %{workspace_id: id}}} =
             TurnStorage.accept_message(actor, daily.id, %{message: report})

    assert id == workspace.id

    {:ok, _} = Threads.delete(actor, workspace.id)

    assert {:error, :workspace_gone} =
             TurnStorage.accept_message(actor, daily.id, %{message: report})

    refute Enum.any?(Threads.messages(actor, daily.id), &(&1.workspace_id == workspace.id))
  end

  # ---------------------------------------------------------------------------
  # The five statuses: working, needs you, finished, stopped, error
  # ---------------------------------------------------------------------------

  @grant %{grant: :stored, verify: &Arca.Test.Actor.admits/1}

  # A workspace thread whose opening's turn already ended, with nothing
  # said of its work, and a turn of Aqua running in it.
  defp at_work!(actor, daily) do
    workspace = open!(actor, daily)
    [opening] = Threads.messages(actor, workspace.id)
    finish!(actor, opening_turn!(actor, workspace, opening))
    {workspace, running!(actor, workspace)}
  end

  defp ended!(actor, turn, status, attrs \\ %{}) do
    TurnStorage.finish(
      actor,
      turn.id,
      status,
      Map.merge(
        %{fence: turn.fence, error: "the model could not be reached"},
        Map.merge(@grant, attrs)
      )
    )
  end

  defp stop!(actor, workspace),
    do: TurnStorage.stop_work(actor, workspace.id, Map.put(@grant, :error, "stopped"))

  defp outcome(actor, id), do: elem(Threads.get(actor, id), 1).workspace_outcome

  defp open_turns(actor, thread_id) do
    {:ok, turns} = TurnStorage.open_turns(actor, thread_id)
    turns
  end

  defp report_outcomes(actor),
    do: for(r <- records(actor, "workspace_report"), do: r.snapshot["outcome"])

  test "Aqua reports its work done or needing the person, once a turn; failed is no outcome",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)

    assert {:error, :illegal_transition} =
             TurnStorage.report_workspace(actor, turn.id, "failed", %{fence: turn.fence})

    assert records(actor, "workspace_report") == []

    assert {:ok, %{workspace_state: "needs_you"}} =
             TurnStorage.report_workspace(actor, turn.id, "needs_you", %{
               fence: turn.fence,
               summary: "Which account should I use?"
             })

    assert [%{snapshot: snapshot}] = records(actor, "workspace_report")
    assert %{"outcome" => "needs_you", "turn_id" => turn_id} = snapshot
    refute Map.has_key?(snapshot, "approval_id")
    assert turn_id == turn.id

    assert {:error, :reported} =
             TurnStorage.report_workspace(actor, turn.id, "done", %{fence: turn.fence})

    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, workspace.id) == "needs_you"
  end

  for {status, by, state, reported} <- [
        {"completed", nil, "open", nil},
        {"failed", nil, "error", "error"},
        {"uncertain", nil, "error", "error"},
        {"cancelled", :person, "stopped", nil},
        {"cancelled", :recovery, "error", "error"},
        {"cancelled", nil, "open", nil}
      ] do
    @status status
    @by by
    @state state
    @reported reported
    test "a workspace turn that ends #{status} (#{inspect(by)}) with no report leaves it #{state}",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      attrs = if @by, do: %{ended_by: @by}, else: %{}
      assert {:ok, _} = ended!(actor, turn, @status, attrs)

      assert state(actor, workspace.id) == @state

      case @reported do
        nil ->
          assert records(actor, "workspace_report") == []

        outcome ->
          assert [%{snapshot: %{"outcome" => ^outcome, "summary" => summary}}] =
                   records(actor, "workspace_report")

          assert summary == "the model could not be reached"
      end
    end
  end

  test "a turn's end names who cancelled it on a cancel only, by a name storage knows",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)

    assert {:error, :illegal_transition} = ended!(actor, turn, "cancelled", %{ended_by: :bogus})
    assert {:error, :illegal_transition} = ended!(actor, turn, "failed", %{ended_by: :person})
    assert [_running] = open_turns(actor, workspace.id)
  end

  test "an error a later report answers: new work opens the thread, and its report is what it says",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)
    {:ok, _} = ended!(actor, turn, "failed")
    assert state(actor, workspace.id) == "error"

    again = running!(actor, workspace)
    assert state(actor, workspace.id) == "open"
    assert outcome(actor, workspace.id) == nil

    {:ok, _} = TurnStorage.report_workspace(actor, again.id, "done", %{fence: again.fence})
    {:ok, _} = ended!(actor, again, "completed")
    assert state(actor, workspace.id) == "done"
    assert report_outcomes(actor) == ["error", "done"]
  end

  test "Aqua's needs_you before the person's post is cleared by it; after it, it is the last word",
       %{actor: actor, daily: daily} do
    # The report first, then the person's post: new work clears it.
    {first, turn} = at_work!(actor, daily)
    {:ok, _} = TurnStorage.report_workspace(actor, turn.id, "needs_you", %{fence: turn.fence})
    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, first.id) == "needs_you"
    answer = running!(actor, first)
    assert outcome(actor, first.id) == nil
    {:ok, _} = ended!(actor, answer, "completed")
    assert state(actor, first.id) == "open"

    # The person's post first, its turn queued behind Aqua's, then Aqua's
    # report: the thread works while the post's turn waits, and once that
    # ends with nothing said, the report is the last word.
    {:ok, other} = Arca.Test.Days.thread(actor)
    {second, turn} = at_work!(actor, other)

    {:ok, %{turn: post}} =
      TurnStorage.accept_message(actor, second.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "and also"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    {:ok, _} = TurnStorage.report_workspace(actor, turn.id, "needs_you", %{fence: turn.fence})
    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, second.id) == "open"
    {:ok, _} = ended!(actor, post, "cancelled")
    assert state(actor, second.id) == "needs_you"
  end

  describe "the person's stop" do
    test "with Aqua running: its turn ends, the thread reads stopped, nothing is reported",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)

      assert {:ok, %{cancelled: [%{turn_id: id, thread_id: thread_id}]}} = stop!(actor, workspace)
      assert {id, thread_id} == {turn.id, workspace.id}
      assert {:ok, %{status: "cancelled"}} = TurnStorage.get(actor, turn.id)
      assert state(actor, workspace.id) == "stopped"
      assert open_turns(actor, workspace.id) == []
      assert records(actor, "workspace_report") == []
    end

    test "with a crew member running and Aqua idle: the member's turn ends with no reply",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      member = running!(actor, child)
      {:ok, _} = ended!(actor, turn, "completed")
      assert state(actor, workspace.id) == "open"

      assert {:ok, %{cancelled: [%{turn_id: id}]}} = stop!(actor, workspace)
      assert id == member.id
      assert state(actor, workspace.id) == "stopped"
      assert open_turns(actor, child.id) == []
      assert {:ok, []} = Arca.Outbox.pending(actor, "crew_delivery", "crew_reply")
      assert records(actor, "workspace_report") == []
    end

    test "with Aqua and a crew member running: all ends",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      member = running!(actor, child)

      assert {:ok, %{cancelled: cancelled}} = stop!(actor, workspace)
      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([turn.id, member.id])
      assert state(actor, workspace.id) == "stopped"
      assert records(actor, "workspace_report") == []
    end

    test "with an opening queued: it starts nothing after, and the thread reads stopped",
         %{actor: actor, daily: daily} do
      workspace = open!(actor, daily)
      [opening] = Threads.messages(actor, workspace.id)
      assert state(actor, workspace.id) == "open"

      assert {:ok, %{cancelled: []}} = stop!(actor, workspace)
      assert state(actor, workspace.id) == "stopped"
      assert {:ok, %{status: "expired"}} = Threads.get_message(actor, opening.id)

      assert {:error, :opening_ended} =
               TurnStorage.accept_message(actor, workspace.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: opening.content},
                 opening_id: opening.id,
                 turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
               })

      assert open_turns(actor, workspace.id) == []
    end

    test "with an opening delivered before it: the opening's turn is stopped with the rest",
         %{actor: actor, daily: daily} do
      workspace = open!(actor, daily)
      [opening] = Threads.messages(actor, workspace.id)
      turn = opening_turn!(actor, workspace, opening)

      assert {:ok, %{cancelled: [%{turn_id: id}]}} = stop!(actor, workspace)
      assert id == turn.id
      assert state(actor, workspace.id) == "stopped"
      assert open_turns(actor, workspace.id) == []
    end

    test "a stop that finds nothing to end changes nothing", %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      {:ok, _} = TurnStorage.report_workspace(actor, turn.id, "done", %{fence: turn.fence})
      {:ok, _} = ended!(actor, turn, "completed")
      assert state(actor, workspace.id) == "done"

      assert {:ok, %{cancelled: []}} = stop!(actor, workspace)
      assert state(actor, workspace.id) == "done"
      assert outcome(actor, workspace.id) == "done"
    end

    test "the person's post after a stop is new work", %{actor: actor, daily: daily} do
      {workspace, _turn} = at_work!(actor, daily)
      {:ok, _} = stop!(actor, workspace)

      _again = running!(actor, workspace)
      assert state(actor, workspace.id) == "open"
      assert outcome(actor, workspace.id) == nil
    end

    test "only a workspace thread's work is stopped this way", %{actor: actor, daily: daily} do
      assert {:error, :not_a_workspace} = stop!(actor, daily)
    end
  end

  describe "a stop and a crew member's work, either way round" do
    # A request of the workspace thread to `member`, waiting for its answer.
    defp asked!(actor, workspace, member) do
      {:ok, %{message: row}} =
        TurnStorage.accept_message(actor, workspace.id, %{
          message: %{
            author: "aqua",
            sent_by: "aqua",
            addressee: member,
            status: "pending",
            content: "plan it"
          },
          request: %{
            member: member,
            task: "plan it",
            tools: nil,
            options: %{},
            person_id: actor.user_id,
            origin: :interactive
          }
        })

      row
    end

    defp deliver(actor, workspace, child, request) do
      TurnStorage.accept_message(actor, child.id, %{
        message: %{
          author: actor.user_id,
          sent_by: request.sent_by,
          addressee: child.agent,
          content: request.content,
          payload: %{"request_id" => request.id}
        },
        turn: %{agent: child.agent, requested_by: actor.user_id, origin: :interactive},
        reply_address: %{asking_thread_id: workspace.id, request_id: request.id}
      })
    end

    # The member's answer landing on its room, which wakes Aqua there.
    defp answer(actor, workspace, request) do
      TurnStorage.accept_message(actor, workspace.id, %{
        message: %{
          author: "aqua",
          sent_by: request.addressee,
          addressee: "aqua",
          reply_to: request.id,
          outcome: "done",
          content: "the plan"
        },
        answers: [request.id],
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })
    end

    test "a request reads unstarted until a turn opens for it, and stays waiting after it ends",
         %{actor: actor, daily: daily} do
      {workspace, _turn} = at_work!(actor, daily)
      request = asked!(actor, workspace, "planner")

      unstarted = fn ->
        Threads.pending_requests(actor, thread_id: workspace.id, unstarted: true)
      end

      assert [%{id: id}] = unstarted.()
      assert id == request.id

      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      {:ok, %{turn: member}} = deliver(actor, workspace, child, request)
      assert unstarted.() == []
      finish!(actor, member)
      assert unstarted.() == []
      assert [_waiting] = Threads.pending_requests(actor, thread_id: workspace.id)
    end

    test "a request delivered before the stop: its turn is stopped with the rest",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      request = asked!(actor, workspace, "planner")
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      {:ok, %{turn: member}} = deliver(actor, workspace, child, request)
      {:ok, _} = ended!(actor, turn, "completed")

      assert {:ok, %{cancelled: [%{turn_id: id}]}} = stop!(actor, workspace)
      assert id == member.id
      assert state(actor, workspace.id) == "stopped"
      assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
    end

    test "a request delivered after the stop lands nothing", %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      request = asked!(actor, workspace, "planner")
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      {:ok, _} = ended!(actor, turn, "completed")
      assert state(actor, workspace.id) == "open"

      {:ok, _} = stop!(actor, workspace)
      assert state(actor, workspace.id) == "stopped"
      assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
      assert {:error, :request_ended} = deliver(actor, workspace, child, request)
      assert open_turns(actor, child.id) == []
    end

    test "an answer that lands before the stop wakes Aqua, whose turn the stop ends",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      request = asked!(actor, workspace, "planner")
      {:ok, _} = ended!(actor, turn, "completed")
      assert {:ok, %{turn: %{id: woken}}} = answer(actor, workspace, request)

      assert {:ok, %{cancelled: [%{turn_id: ^woken}]}} = stop!(actor, workspace)
      assert state(actor, workspace.id) == "stopped"
    end

    test "an answer on its way when the stop lands is a row and wakes nothing",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      request = asked!(actor, workspace, "planner")
      {:ok, _} = ended!(actor, turn, "completed")
      {:ok, _} = stop!(actor, workspace)

      assert {:ok, %{message: row, turn: nil}} = answer(actor, workspace, request)
      assert row.reply_to == request.id
      assert open_turns(actor, workspace.id) == []
      assert state(actor, workspace.id) == "stopped"
    end
  end

  test "an opening refused for good ends it and reports an error with no turn, once",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)
    [opening] = Threads.messages(actor, workspace.id)

    refuse = fn ->
      TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
        summary: "the work could not start (a limit was reached)",
        person_id: actor.user_id,
        origin: "interactive"
      })
    end

    assert {:ok, %{workspace_state: "error"}} = refuse.()
    assert {:ok, %{status: "error"}} = Threads.get_message(actor, opening.id)

    assert [%{snapshot: %{"outcome" => "error", "sources" => []} = snapshot}] =
             records(actor, "workspace_report")

    assert snapshot["turn_id"] == nil
    assert snapshot["summary"] == "the work could not start (a limit was reached)"
    assert {:error, :opening_ended} = refuse.()
    assert length(records(actor, "workspace_report")) == 1

    assert {:error, :opening_ended} =
             TurnStorage.accept_message(actor, workspace.id, %{
               message: %{author: actor.user_id, sent_by: "person", content: opening.content},
               opening_id: opening.id,
               turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
             })
  end

  test "an opening refused after a report of earlier work since it was written ends on its own row alone",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)

    {:ok, _again} =
      TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))

    opening =
      Enum.find(
        Threads.messages(actor, workspace.id),
        &(&1.kind == "opening" and is_nil(&1.turn_id))
      )

    {:ok, _} =
      TurnStorage.report_workspace(actor, turn.id, "done", %{fence: turn.fence, summary: "Done."})

    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, workspace.id) == "open"

    assert {:ok, %{workspace_state: "done"}} =
             TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
               summary: "the work could not start",
               person_id: actor.user_id,
               origin: "interactive"
             })

    assert {:ok, %{status: "error"}} = Threads.get_message(actor, opening.id)
    assert outcome(actor, workspace.id) == "done"
    assert report_outcomes(actor) == ["done"]
  end

  test "an opening refused after a newer post's report leaves that report the thread's word", %{
    actor: actor,
    daily: daily
  } do
    workspace = open!(actor, daily)
    [opening] = Threads.messages(actor, workspace.id)
    newer = running!(actor, workspace)

    assert {:ok, _} =
             TurnStorage.report_workspace(actor, newer.id, "done", %{
               fence: newer.fence,
               summary: "New work finished"
             })

    assert {:ok, _} = ended!(actor, newer, "completed")
    assert outcome(actor, workspace.id) == "done"

    assert {:ok, _} =
             TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
               summary: "old delivery refused",
               person_id: actor.user_id,
               origin: "interactive"
             })

    assert state(actor, workspace.id) == "done"
    assert outcome(actor, workspace.id) == "done"
  end

  test "an answer to a request the stop ended opens no turn after new work reopens the thread",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)
    request = asked!(actor, workspace, "planner")
    assert {:ok, _} = ended!(actor, turn, "completed")
    assert {:ok, _} = stop!(actor, workspace)
    assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
    _newer = running!(actor, workspace)
    assert state(actor, workspace.id) == "open"
    assert {:ok, %{message: row, turn: nil}} = answer(actor, workspace, request)
    assert row.reply_to == request.id
  end

  test "an opening stamped ahead of the report written after it leaves that report the thread's word",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)

    {:ok, _} =
      TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))

    opening =
      Enum.find(
        Threads.messages(actor, workspace.id),
        &(&1.kind == "opening" and is_nil(&1.turn_id))
      )

    # The opening's writer's clock ahead of the database's.
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^actor.athanor_id and m.id == ^opening.id
    )
    |> Arca.Repo.update_all(set: [inserted_at: DateTime.add(opening.inserted_at, 300, :second)])

    {:ok, _} =
      TurnStorage.report_workspace(actor, turn.id, "done", %{
        fence: turn.fence,
        summary: "Done after the opening."
      })

    {:ok, _} = ended!(actor, turn, "completed")
    assert outcome(actor, workspace.id) == "done"

    {:ok, _} =
      TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
        summary: "old opening refused",
        person_id: actor.user_id,
        origin: "interactive"
      })

    assert outcome(actor, workspace.id) == "done"
    assert state(actor, workspace.id) == "done"
    assert report_outcomes(actor) == ["done"]
  end

  test "an opening stamped behind the report written before it is refused with its error", %{
    actor: actor,
    daily: daily
  } do
    {workspace, turn} = at_work!(actor, daily)

    {:ok, _} =
      TurnStorage.report_workspace(actor, turn.id, "done", %{
        fence: turn.fence,
        summary: "Old work done."
      })

    {:ok, _} = ended!(actor, turn, "completed")

    {:ok, _} =
      TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))

    opening =
      Enum.find(
        Threads.messages(actor, workspace.id),
        &(&1.kind == "opening" and is_nil(&1.turn_id))
      )

    # The opening's writer's clock behind the database's.
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^actor.athanor_id and m.id == ^opening.id
    )
    |> Arca.Repo.update_all(set: [inserted_at: DateTime.add(opening.inserted_at, -300, :second)])

    assert outcome(actor, workspace.id) == nil

    {:ok, _} =
      TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
        summary: "new work could not start",
        person_id: actor.user_id,
        origin: "interactive"
      })

    assert outcome(actor, workspace.id) == "error"
    assert state(actor, workspace.id) == "error"
    assert report_outcomes(actor) == ["done", "error"]
  end

  describe "an opening refused for good, by the thread's own order" do
    defp refuse(actor, workspace, opening) do
      TurnStorage.refuse_opening(actor, workspace.id, opening.id, %{
        summary: "the work could not start",
        person_id: actor.user_id,
        origin: "interactive"
      })
    end

    defp asked_again!(actor, daily, workspace) do
      {:ok, _} =
        TurnStorage.open_workspace(actor, opening(actor, daily, %{workspace_id: workspace.id}))

      workspace.id
      |> then(&Threads.messages(actor, &1))
      |> Enum.filter(&(&1.kind == "opening" and is_nil(&1.turn_id) and is_nil(&1.status)))
      |> List.last()
    end

    test "of several openings, only the newest that is still the newest word speaks, in either order",
         %{actor: actor, daily: daily} do
      # The older refused first, then the newer.
      {first, turn} = at_work!(actor, daily)
      older = asked_again!(actor, daily, first)
      newer = asked_again!(actor, daily, first)
      {:ok, _} = ended!(actor, turn, "cancelled")

      {:ok, _} = refuse(actor, first, older)
      assert outcome(actor, first.id) == nil
      assert records(actor, "workspace_report") == []
      {:ok, _} = refuse(actor, first, newer)
      assert outcome(actor, first.id) == "error"
      assert report_outcomes(actor) == ["error"]

      # The newer refused first, then the older: its refusal is past.
      {:ok, other} = Arca.Test.Days.thread(actor)
      {second, turn} = at_work!(actor, other)
      older = asked_again!(actor, other, second)
      newer = asked_again!(actor, other, second)
      {:ok, _} = ended!(actor, turn, "cancelled")

      {:ok, _} = refuse(actor, second, newer)
      {:ok, _} = refuse(actor, second, older)
      assert {:ok, %{status: "error"}} = Threads.get_message(actor, older.id)
      assert state(actor, second.id) == "error"
      assert report_outcomes(actor) == ["error", "error"]
    end

    test "a stop or an error written with no report since the opening is the thread's later word",
         %{actor: actor, daily: daily} do
      # The person's stop of the running turn, after the opening.
      {stopped, turn} = at_work!(actor, daily)
      waiting = asked_again!(actor, daily, stopped)
      {:ok, _} = ended!(actor, turn, "cancelled", %{ended_by: :person})
      assert outcome(actor, stopped.id) == "stopped"

      {:ok, _} = refuse(actor, stopped, waiting)
      assert outcome(actor, stopped.id) == "stopped"
      assert records(actor, "workspace_report") == []

      # An error no report could tell: its turn's stored origin reads as none.
      {:ok, other} = Arca.Test.Days.thread(actor)
      {failed, turn} = at_work!(actor, other)
      waiting = asked_again!(actor, other, failed)

      {1, _} =
        from(t in Arca.Schemas.Turn, where: t.id == ^turn.id)
        |> Arca.Repo.update_all(set: [origin: "hand-edited"])

      {:ok, _} = ended!(actor, turn, "cancelled", %{ended_by: :recovery})
      assert outcome(actor, failed.id) == "error"
      assert records(actor, "workspace_report") == []

      {:ok, _} = refuse(actor, failed, waiting)
      assert outcome(actor, failed.id) == "error"
      assert records(actor, "workspace_report") == []
    end

    test "a report or a person's post either side of the refusal: the later word stands",
         %{actor: actor, daily: daily} do
      # The refusal first, then the running turn's report: the report stands.
      {first, turn} = at_work!(actor, daily)
      waiting = asked_again!(actor, daily, first)
      {:ok, _} = refuse(actor, first, waiting)
      assert outcome(actor, first.id) == "error"
      {:ok, _} = TurnStorage.report_workspace(actor, turn.id, "done", %{fence: turn.fence})
      {:ok, _} = ended!(actor, turn, "completed")
      assert state(actor, first.id) == "done"
      assert report_outcomes(actor) == ["error", "done"]

      # The refusal first, then the person's post: new work clears it.
      {:ok, other} = Arca.Test.Days.thread(actor)
      {second, turn} = at_work!(actor, other)
      waiting = asked_again!(actor, other, second)
      {:ok, _} = ended!(actor, turn, "cancelled")
      {:ok, _} = refuse(actor, second, waiting)
      assert state(actor, second.id) == "error"
      _post = running!(actor, second)
      assert outcome(actor, second.id) == nil
      assert state(actor, second.id) == "open"
    end
  end
end
