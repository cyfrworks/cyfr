# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WorkspaceStorageTest.PausingDelete do
  @moduledoc false
  use Arca.Storage.TestDouble

  # The first thread tree this process deletes runs the test's hook first:
  # what a person does the moment retention's bytes start to go.
  def delete_tree(actor, ["threads", _id] = path) do
    if hook = Process.delete(:on_blob_delete), do: hook.()
    Arca.Adapters.Local.delete_tree(actor, path)
  end

  def delete_tree(actor, path), do: Arca.Adapters.Local.delete_tree(actor, path)
end

defmodule Arca.WorkspaceStorageTest do
  @moduledoc """
  A workspace thread's rows: opened in one transaction with its opening,
  its pointer and its record, or none of them; its state moved by the
  write that moves it, a card in it or in a crew member's thread under it
  among them; and a row that names it landing only while it stands.
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

  defp decline!(actor, turn, approval) do
    {:ok, _} =
      TurnStorage.resolve_approval(actor, approval.id, "declined", %{
        fence: turn.fence,
        resolution_kind: Prima.TurnState.resolution_kind("declined", "tool"),
        denied_result: %{content: "declined", payload: %{}}
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

  test "a card in a workspace thread, or in a crew member's thread under it, waits on the person and reports once; the last one decided puts it back to work",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)
    own = running!(actor, workspace)
    first = card!(actor, own, "k1")

    assert state(actor, workspace.id) == "needs_you"

    assert [%{snapshot: %{"outcome" => "needs_you", "approval_id" => approval_id}}] =
             records(actor, "workspace_report")

    assert approval_id == first.id

    {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
    member = running!(actor, child)
    second = card!(actor, member, "k2")
    assert length(records(actor, "workspace_report")) == 1

    decline!(actor, own, first)
    assert state(actor, workspace.id) == "needs_you"

    decline!(actor, member, second)
    assert state(actor, workspace.id) == "open"
    assert length(records(actor, "workspace_report")) == 1

    # At work again, a crew member's card waits on the person once more.
    {:ok, member} = TurnStorage.get(actor, member.id)
    _third = card!(actor, member, "k3")
    assert state(actor, workspace.id) == "needs_you"
    assert [_, %{snapshot: %{"turn_id" => turn_id}}] = records(actor, "workspace_report")
    assert turn_id == member.id

    # A card its turn's cancel invalidates settles it too.
    {:ok, _} = TurnStorage.skip_steps(actor, member.id, "stopped", %{fence: member.fence})
    assert state(actor, workspace.id) == "open"
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

  test "retention keeps a thread an open turn has read, which it cannot stop without the turn's root grant",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)
    reader = running!(actor, daily)
    read = Prima.Source.encode([Prima.Source.thread(workspace.id)])

    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Turn, where: t.id == ^reader.id),
        set: [sources: read]
      )

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Thread, where: c.id == ^workspace.id),
        set: [workspace_state: "done"]
      )

    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert {:ok, 0} = Threads.count_before(actor, future)
    assert {:ok, 0} = Threads.delete_before(actor, future)
    assert {:ok, _kept} = Threads.get(actor, workspace.id)

    # Forgetting it would stop the open turn that read it, and stopping a
    # turn with a root ends its attempt under the root's grant, which
    # retention does not hold: a deletion that names none is refused.
    assert {:error, :missing_grant} = Threads.delete(actor, workspace.id)

    # Once that turn has ended, retention forgets the thread.
    {:ok, _} =
      TurnStorage.finish(actor, reader.id, "failed", %{
        fence: reader.fence,
        error: "stopped",
        grant: :stored,
        verify: &Arca.Test.Actor.admits/1
      })

    assert {:ok, removed} = Threads.delete_before(actor, future)
    assert removed >= 1
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

  test "a report while a crew member's card waits lands and leaves the thread waiting; once the last card is settled and nothing else remains, it is what the report said",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)
    [opening] = Threads.messages(actor, workspace.id)
    own = opening_turn!(actor, workspace, opening)
    {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
    member = running!(actor, child)
    card = card!(actor, member, "k1")
    assert state(actor, workspace.id) == "needs_you"

    assert {:ok, %{workspace_state: "needs_you"}} =
             TurnStorage.report_workspace(actor, own.id, "done", %{
               fence: own.fence,
               summary: "Done."
             })

    assert state(actor, workspace.id) == "needs_you"

    assert ["needs_you", "done"] =
             for(record <- records(actor, "workspace_report"), do: record.snapshot["outcome"])

    # Decided, the card leaves the member's turn still running: at work.
    decline!(actor, member, card)
    assert state(actor, workspace.id) == "open"

    # The member's turn ends and nothing else remains: what the report said.
    finish!(actor, member)
    assert state(actor, workspace.id) == "done"
    assert length(records(actor, "workspace_report")) == 2
  end

  # Retention decides under the rows it deletes.
  test "a person's post that lands as retention removes a thread keeps the thread, or finds it gone",
       %{actor: actor, daily: daily} do
    workspace = open!(actor, daily)

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Thread, where: c.id == ^workspace.id),
        set: [workspace_state: "done"]
      )

    # The daily thread stays by a turn still open there.
    _open = running!(actor, daily)
    future = DateTime.add(DateTime.utc_now(), 3600, :second)

    me = self()

    Process.put(:on_blob_delete, fn ->
      posted =
        TurnStorage.accept_message(actor, workspace.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "one more thing"}
        })

      send(me, {:posted, posted})
    end)

    assert {:ok, _removed} =
             Prima.Test.Env.with_app_env(
               :arca,
               :storage_adapter,
               Arca.WorkspaceStorageTest.PausingDelete,
               fn -> Threads.delete_before(actor, future) end
             )

    assert_received {:posted, posted}

    case posted do
      {:ok, _landed} ->
        assert {:ok, %{workspace_state: "open"}} = Threads.get(actor, workspace.id)

      {:error, _gone} ->
        assert {:error, :not_found} = Threads.get(actor, workspace.id)
    end
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

  test "a card's notice is no report of the turn's work, and Aqua's needs_you outlasts a card",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)
    card = card!(actor, turn, "k1")
    assert state(actor, workspace.id) == "needs_you"

    # The notice leaves the turn its own report.
    assert {:ok, %{workspace_state: "needs_you"}} =
             TurnStorage.report_workspace(actor, turn.id, "needs_you", %{
               fence: turn.fence,
               summary: "Tell me the date."
             })

    assert [%{"approval_id" => _}, authored] =
             for(r <- records(actor, "workspace_report"), do: r.snapshot)

    refute Map.has_key?(authored, "approval_id")

    # Deciding the card clears its own wait only.
    decline!(actor, turn, card)
    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, workspace.id) == "needs_you"
  end

  test "the person's answer clears Aqua's needs_you and leaves a card that still waits waiting",
       %{actor: actor, daily: daily} do
    {workspace, turn} = at_work!(actor, daily)
    {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
    member = running!(actor, child)
    card = card!(actor, member, "k1")
    {:ok, _} = TurnStorage.report_workspace(actor, turn.id, "needs_you", %{fence: turn.fence})
    {:ok, _} = ended!(actor, turn, "completed")
    assert state(actor, workspace.id) == "needs_you"

    answer = running!(actor, workspace)
    assert outcome(actor, workspace.id) == nil
    assert state(actor, workspace.id) == "needs_you"

    decline!(actor, member, card)
    assert state(actor, workspace.id) == "open"

    finish!(actor, member)
    {:ok, _} = ended!(actor, answer, "completed")
    assert state(actor, workspace.id) == "open"
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

    test "with Aqua and a crew member running, a card waiting: all ends, the card with it",
         %{actor: actor, daily: daily} do
      {workspace, turn} = at_work!(actor, daily)
      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      member = running!(actor, child)
      card = card!(actor, member, "k1")
      assert state(actor, workspace.id) == "needs_you"
      [notice] = records(actor, "workspace_report")

      assert {:ok, %{cancelled: cancelled}} = stop!(actor, workspace)
      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([turn.id, member.id])
      assert state(actor, workspace.id) == "stopped"
      assert {:ok, %{status: status}} = TurnStorage.approval(actor, card.id)
      assert status != "pending"
      assert records(actor, "workspace_report") == [notice]
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
end
