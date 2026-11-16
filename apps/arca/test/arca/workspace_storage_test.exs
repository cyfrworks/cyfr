# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WorkspaceStorageTest do
  @moduledoc """
  A workspace thread's rows: opened in one transaction with its opening,
  its pointer and its record, or none of them; its state moved by the
  write that moves it, a card in it or in a crew member's thread under it
  among them; and a row that names it landing only while it stands.
  """

  use ExUnit.Case, async: false

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
