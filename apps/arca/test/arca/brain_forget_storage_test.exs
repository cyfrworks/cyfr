# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BrainForgetStorageTest do
  @moduledoc """
  The removals a forgetting owes (`Prima.OutboxRecord.brain_forget/1`),
  recorded in the transaction that clears or deletes a thread's brain
  session, before the statement that does: a deleted room's session, each
  of its children's and each of its readers', and the sessions a home's
  reset forgets. A session no program holds, an API brain's or one whose
  start no driven program with a kept folder admitted, owes nothing; a
  deletion refused records nothing. Every check reads the whole record
  the store holds.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  @consumer "brain_cleanup"
  @kind "brain_forget"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, room} = Arca.Test.Days.thread(actor)
    {:ok, actor: actor, room: room, row: brain_row!(actor)}
  end

  defp brain_row!(actor, attrs \\ %{}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(
        actor,
        Map.merge(
          %{
            cap: 0,
            name: "claude-code-#{System.unique_integer([:positive])}",
            transport: "program",
            mark: "driven",
            url: nil,
            home: "kept",
            memory_bytes: 1_073_741_824,
            config_json:
              Jason.encode!(%{
                "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
                "env" => %{}
              })
          },
          attrs
        )
      )

    row
  end

  # A turn of `agent` in `thread` whose `program.start` of `row` was
  # recorded and, unless `dispatch: false`, dispatched as an admitted
  # start is; the turn then ends, as a session outlives its turn.
  defp started!(actor, thread, row, agent, opts \\ []) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: agent, requested_by: actor.user_id, origin: :interactive}
      })

    set_turn!(turn, status: "running")
    {:ok, model} = TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})

    {:ok, %{calls: [%{step: step}]}} =
      TurnStorage.record_response(actor, turn.id, model.id, %{
        fence: turn.fence,
        tool_calls: [
          %{
            tool_call_id: "call_#{System.unique_integer([:positive])}",
            name: "program",
            tool: "program",
            action: "start",
            arguments: %{"action" => "start", "program" => row.id, "epoch" => row.epoch}
          }
        ]
      })

    if Keyword.get(opts, :dispatch, true),
      do: {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})

    set_turn!(turn, status: "completed")
    turn
  end

  defp set_turn!(turn, fields),
    do:
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id), set: fields)

  defp keep!(thread, session, generation \\ 0),
    do:
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          set: [brain_session: session, brain_generation: generation]
        )

  # A turn of `reader` that read `thread`, as a read of it stamps its
  # sources.
  defp reads!(actor, reader, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, reader.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "read it"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    sources = Jason.encode!([Prima.Source.to_json(Prima.Source.thread(thread.id))])
    set_turn!(turn, status: "completed", sources: sources)
  end

  defp record(actor, thread, agent, row, session, generation),
    do:
      Prima.OutboxRecord.brain_forget(%{
        athanor_id: actor.athanor_id,
        thread_id: thread.id,
        agent: agent,
        row_id: row.id,
        session: session,
        generation: generation
      })

  defp owed(actor) do
    {:ok, records} = Arca.Outbox.pending(actor, @consumer, @kind)
    Enum.sort_by(records, & &1.source_id)
  end

  defp sorted(records), do: Enum.sort_by(records, & &1.source_id)

  describe "a deletion" do
    test "records the room's session, each child's and each reader's before their rows go", %{
      actor: actor,
      room: room,
      row: row
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      {:ok, reader} = Arca.Test.Days.thread(actor)
      started!(actor, room, row, "aqua")
      started!(actor, child, row, "planner")
      started!(actor, reader, row, "aqua")
      reads!(actor, reader, room)
      keep!(room, "6f1e2d3c-0000-4968-8776-000000000001", 2)
      keep!(child, "6f1e2d3c-0000-4968-8776-000000000002")
      keep!(reader, "6f1e2d3c-0000-4968-8776-000000000003", 5)
      assert owed(actor) == []

      assert {:ok, %{cancelled: [], forgotten: forgotten}} = Threads.delete(actor, room.id)

      assert Enum.sort_by(forgotten, & &1.thread_id) ==
               Enum.sort_by(
                 [
                   %{thread_id: room.id, agent: "aqua", generation: 2},
                   %{thread_id: child.id, agent: "planner", generation: 0},
                   %{thread_id: reader.id, agent: "aqua", generation: 5}
                 ],
                 & &1.thread_id
               )

      assert owed(actor) ==
               sorted([
                 record(actor, room, "aqua", row, "6f1e2d3c-0000-4968-8776-000000000001", 2),
                 record(actor, child, "planner", row, "6f1e2d3c-0000-4968-8776-000000000002", 0),
                 record(actor, reader, "aqua", row, "6f1e2d3c-0000-4968-8776-000000000003", 5)
               ])

      # The rows went, and the reader's session with its generation raised.
      assert {:error, :not_found} = Threads.get(actor, room.id)
      assert {:error, :not_found} = Threads.get(actor, child.id)
      assert {:ok, %{brain_session: nil, brain_generation: 6}} = Threads.get(actor, reader.id)
    end

    test "a refused deletion records nothing", %{actor: actor, room: room, row: row} do
      started!(actor, room, row, "aqua")
      keep!(room, "6f1e2d3c-0000-4968-8776-000000000001")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, child.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "wait"},
          turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
        })

      set_turn!(turn, status: "paused", paused_reason: "approval")

      assert {:error, {:child_awaits_card, "planner"}} = Threads.delete(actor, room.id)
      assert owed(actor) == []

      assert {:ok, %{brain_session: "6f1e2d3c-0000-4968-8776-000000000001"}} =
               Threads.get(actor, room.id)
    end
  end

  describe "a session no program holds" do
    test "owes nothing: an API brain's, a start not admitted, a row that keeps no folder or is gone",
         %{actor: actor, room: room, row: row} do
      {:ok, proposed} = Arca.Test.Days.thread(actor)
      {:ok, scratch} = Arca.Test.Days.thread(actor)
      {:ok, gone} = Arca.Test.Days.thread(actor)
      started!(actor, proposed, row, "aqua", dispatch: false)
      started!(actor, scratch, brain_row!(actor, %{home: "scratch"}), "aqua")
      vanished = brain_row!(actor)
      started!(actor, gone, vanished, "aqua")

      {1, _} =
        Arca.Repo.delete_all(from(r in Arca.Schemas.McpServer, where: r.id == ^vanished.id))

      # The room's session is an API brain's: no start of a program names it.
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^room.id),
          set: [agent: "aqua"]
        )

      for thread <- [room, proposed, scratch, gone], do: keep!(thread, "a-session")

      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])
      assert owed(actor) == []

      for thread <- [room, proposed, scratch, gone],
          do:
            assert(
              {:ok, %{brain_session: nil, brain_generation: 1}} =
                Threads.get(actor, thread.id)
            )
    end

    test "the latest admitted start names the row", %{actor: actor, room: room, row: row} do
      later = brain_row!(actor)
      started!(actor, room, row, "aqua")
      started!(actor, room, later, "aqua")
      started!(actor, room, row, "aqua", dispatch: false)
      keep!(room, "6f1e2d3c-0000-4968-8776-000000000001")

      assert {:ok, [%{thread_id: _, agent: "aqua", generation: 0}]} =
               Threads.forget_sessions(actor, ["aqua"])

      assert owed(actor) == [
               record(actor, room, "aqua", later, "6f1e2d3c-0000-4968-8776-000000000001", 0)
             ]
    end
  end

  describe "a home's reset" do
    test "records each session it forgets before it clears it, one per generation", %{
      actor: actor,
      room: room,
      row: row
    } do
      started!(actor, room, row, "aqua")
      keep!(room, "6f1e2d3c-0000-4968-8776-000000000001")

      assert {:ok, [%{thread_id: id, agent: "aqua", generation: 0}]} =
               Threads.forget_sessions(actor, ["aqua"])

      assert id == room.id
      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, room.id)

      first = record(actor, room, "aqua", row, "6f1e2d3c-0000-4968-8776-000000000001", 0)
      assert owed(actor) == [first]

      # A session kept under the raised generation is its own removal.
      keep!(room, "6f1e2d3c-0000-4968-8776-000000000002", 1)
      assert {:ok, [%{generation: 1}]} = Threads.forget_sessions(actor, ["aqua"])

      assert owed(actor) ==
               sorted([
                 first,
                 record(actor, room, "aqua", row, "6f1e2d3c-0000-4968-8776-000000000002", 1)
               ])

      # A forget with no session left owes nothing more.
      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])
      assert length(owed(actor)) == 2
    end

    test "a session kept after the forget, under the generation it left, is not kept and owes nothing",
         %{actor: actor, room: room, row: row} do
      started!(actor, room, row, "aqua")
      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])

      # A turn that read generation 0 keeps nothing it answers with now
      # (`keep_session!`), so nothing is left that a transcript backs.
      {0, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Thread, where: t.id == ^room.id and t.brain_generation == 0),
          set: [brain_session: "late"]
        )

      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, room.id)
      assert owed(actor) == []
    end
  end
end
