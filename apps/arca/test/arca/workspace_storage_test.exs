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
             TurnStorage.report_workspace(actor, one.id, "failed", %{
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
end
