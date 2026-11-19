# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BrainForgetStorageTest do
  @moduledoc """
  The removals a forgetting owes (`Prima.OutboxRecord.brain_forget/1`),
  recorded in the transaction that clears or deletes a thread's brain
  session, before the statement that does: a deleted room's session, each
  of its children's and each of its readers', the sessions a home's
  reset forgets, and a lost transcript's when the session is stored with
  another row than the one whose brain lost it. Each names the row the
  session is stored with, as the batch that keeps it stores it
  (`Arca.TurnStorage.commit_brain/3`). A session stored with no row, an
  adapter catalyst's, or with a row gone or keeping no folder, owes
  nothing; a deletion refused records nothing. Every check reads the
  whole record the store holds.
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

  # A turn of `agent` addressed in `thread`, over.
  defp addressed!(actor, thread, agent) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "hello"},
        turn: %{agent: agent, requested_by: actor.user_id, origin: :interactive}
      })

    set_turn!(turn, status: "completed")
    turn
  end

  # `session` kept as a driver's `started` keeps it, on `row`, at the
  # thread's `generation`, by a turn of `agent`: the batch that names it
  # stores the row with it.
  defp held!(actor, thread, row, agent, session, generation \\ 0) do
    addressed!(actor, thread, agent)

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
        set: [brain_generation: generation]
      )

    {:ok, %{seen: false}} = batch(actor, thread, row, agent, generation, %{session: session})
  end

  # One batch of a new driver process of `row`, its hello among its lines.
  defp batch(actor, thread, row, agent, generation, attrs),
    do:
      TurnStorage.commit_brain(
        actor,
        thread.id,
        Map.merge(
          %{
            agent: agent,
            generation: generation,
            boot: "boot-#{System.unique_integer([:positive])}",
            hello: true,
            seq: 1,
            row_id: row.id,
            epoch: row.epoch,
            silence_ms: 1_800_000
          },
          attrs
        )
      )

  # An open turn of "aqua" in `thread` whose brain runs on `row` (none
  # for a catalyst's).
  defp running!(actor, thread, row) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go on"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    set_turn!(turn, status: "running")

    if row,
      do: {:ok, _} = TurnStorage.pin_program(actor, turn.id, row.id, %{fence: turn.fence})

    turn
  end

  # A turn of `reader` that read `thread`, as a read of it stamps its
  # read threads.
  defp reads!(actor, reader, thread) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, reader.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "read it"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    set_turn!(turn,
      status: "completed",
      read_threads: Arca.ThreadStorage.threads_text([thread.id])
    )
  end

  defp record(actor, thread, row, session, generation),
    do:
      Prima.OutboxRecord.brain_forget(%{
        athanor_id: actor.athanor_id,
        thread_id: thread.id,
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
      held!(actor, room, row, "aqua", "6f1e2d3c-0000-4968-8776-000000000001", 2)
      held!(actor, child, row, "planner", "6f1e2d3c-0000-4968-8776-000000000002")
      held!(actor, reader, row, "aqua", "6f1e2d3c-0000-4968-8776-000000000003", 5)
      reads!(actor, reader, room)
      assert owed(actor) == []

      assert {:ok, %{cancelled: [], forgotten: forgotten}} = Threads.delete(actor, room.id)

      assert Enum.sort_by(forgotten, & &1.thread_id) ==
               Enum.sort_by(
                 [
                   %{thread_id: room.id, generation: 2},
                   %{thread_id: child.id, generation: 0},
                   %{thread_id: reader.id, generation: 5}
                 ],
                 & &1.thread_id
               )

      assert owed(actor) ==
               sorted([
                 record(actor, room, row, "6f1e2d3c-0000-4968-8776-000000000001", 2),
                 record(actor, child, row, "6f1e2d3c-0000-4968-8776-000000000002", 0),
                 record(actor, reader, row, "6f1e2d3c-0000-4968-8776-000000000003", 5)
               ])

      # The rows went, and the reader's session with its generation raised.
      assert {:error, :not_found} = Threads.get(actor, room.id)
      assert {:error, :not_found} = Threads.get(actor, child.id)
      assert {:ok, %{brain_session: nil, brain_generation: 6}} = Threads.get(actor, reader.id)
    end

    test "a refused deletion records nothing", %{actor: actor, room: room, row: row} do
      held!(actor, room, row, "aqua", "6f1e2d3c-0000-4968-8776-000000000001")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, child.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "wait"},
          turn: %{agent: "planner", requested_by: actor.user_id, origin: :interactive}
        })

      # A running child turn ends only under its root's grant, which this
      # deletion does not carry.
      set_turn!(turn, status: "running", attempt: "att_planner")

      assert {:error, :missing_grant} = Threads.delete(actor, room.id)
      assert owed(actor) == []

      assert {:ok, %{brain_session: "6f1e2d3c-0000-4968-8776-000000000001"}} =
               Threads.get(actor, room.id)
    end
  end

  describe "the row a session is stored with" do
    test "a catalyst's session, one stored with a row that keeps no folder or is gone, owe nothing",
         %{actor: actor, room: room} do
      {:ok, scratch} = Arca.Test.Days.thread(actor)
      {:ok, gone} = Arca.Test.Days.thread(actor)
      held!(actor, scratch, brain_row!(actor, %{home: "scratch"}), "aqua", "a-session")
      vanished = brain_row!(actor)
      held!(actor, gone, vanished, "aqua", "a-session")

      {1, _} =
        Arca.Repo.delete_all(from(r in Arca.Schemas.McpServer, where: r.id == ^vanished.id))

      # The room's session is a catalyst's: kept with no row.
      addressed!(actor, room, "aqua")
      keep!(room, "a-session")

      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])
      assert owed(actor) == []

      for thread <- [room, scratch, gone],
          do:
            assert(
              {:ok, %{brain_session: nil, brain_generation: 1}} =
                Threads.get(actor, thread.id)
            )
    end

    test "names the session's own row, neither a start admitted after it nor a new driver's",
         %{actor: actor, room: room, row: row} do
      later = brain_row!(actor)
      session = "6f1e2d3c-0000-4968-8776-000000000001"
      held!(actor, room, row, "aqua", session)

      # A later turn's start of another row is admitted, and that row's
      # driver says hello, before any session answers there.
      started!(actor, room, later, "aqua")
      {:ok, %{seen: false}} = batch(actor, room, later, "aqua", 0, %{})

      assert {:ok, %{session: ^session, progress: %{"row" => row_id, "driver" => driver}}} =
               TurnStorage.brain(actor, room.id)

      assert {row_id, driver["row"]} == {row.id, later.id}
      assert {:ok, %{}} = Threads.delete(actor, room.id)
      assert owed(actor) == [record(actor, room, row, session, 0)]
    end
  end

  describe "a home's reset" do
    test "records each session it forgets before it clears it, one per generation", %{
      actor: actor,
      room: room,
      row: row
    } do
      held!(actor, room, row, "aqua", "6f1e2d3c-0000-4968-8776-000000000001")

      assert {:ok, [%{thread_id: id, generation: 0}]} =
               Threads.forget_sessions(actor, ["aqua"])

      assert id == room.id
      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, room.id)

      first = record(actor, room, row, "6f1e2d3c-0000-4968-8776-000000000001", 0)
      assert owed(actor) == [first]

      # A session kept under the raised generation is its own removal.
      held!(actor, room, row, "aqua", "6f1e2d3c-0000-4968-8776-000000000002", 1)
      assert {:ok, [%{generation: 1}]} = Threads.forget_sessions(actor, ["aqua"])

      assert owed(actor) ==
               sorted([
                 first,
                 record(actor, room, row, "6f1e2d3c-0000-4968-8776-000000000002", 1)
               ])

      # A forget with no session left owes nothing more.
      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])
      assert length(owed(actor)) == 2
    end

    test "a session kept after the forget, under the generation it left, is not kept and owes nothing",
         %{actor: actor, room: room, row: row} do
      addressed!(actor, room, "aqua")
      assert {:ok, []} = Threads.forget_sessions(actor, ["aqua"])

      # A batch of the generation the forget left keeps nothing it names.
      assert {:error, :generation_moved} =
               batch(actor, room, row, "aqua", 0, %{session: "late"})

      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, room.id)
      assert owed(actor) == []
    end
  end

  describe "a lost transcript" do
    @session "6f1e2d3c-0000-4968-8776-000000000001"

    test "the row a session is stored with keeps its driver, so its driver's gone is that " <>
           "folder's own answer",
         %{actor: actor, room: room, row: row} do
      held!(actor, room, row, "aqua", @session)
      codex = Jason.encode!(%{"command" => "cyfr-codex codex", "env" => %{}})

      assert Arca.McpServerStorage.update(actor, row.name, %{config_json: codex}) ==
               {:error, :driver_fixed}

      assert Arca.McpServerStorage.get_by_id(actor, row.id) == {:ok, row}
      turn = running!(actor, room, row)

      assert {:ok, 1} =
               TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

      assert owed(actor) == []
    end

    test "the row a session is stored with keeps its folder, so no scratch detour reaches " <>
           "another driver",
         %{actor: actor, room: room, row: row} do
      held!(actor, room, row, "aqua", @session)
      codex = Jason.encode!(%{"command" => "cyfr-codex codex", "env" => %{}})

      assert Arca.McpServerStorage.update(actor, row.name, %{home: "scratch"}) ==
               {:error, :folder_kept}

      assert Arca.McpServerStorage.update(actor, row.name, %{home: "kept", config_json: codex}) ==
               {:error, :driver_fixed}

      assert Arca.McpServerStorage.get_by_id(actor, row.id) == {:ok, row}
    end

    test "lost by the brain of the row the session is stored with owes nothing",
         %{actor: actor, room: room, row: row} do
      held!(actor, room, row, "aqua", @session)
      turn = running!(actor, room, row)

      assert {:ok, 1} =
               TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, room.id)
      assert owed(actor) == []
    end

    test "lost by a brain on another row, or by a catalyst, owes the stored row's removal first",
         %{actor: actor, room: room, row: row} do
      {:ok, other} = Arca.Test.Days.thread(actor)

      for {thread, brain} <- [{room, brain_row!(actor)}, {other, nil}] do
        held!(actor, thread, row, "aqua", @session)
        turn = running!(actor, thread, brain)

        assert {:ok, 1} =
                 TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

        assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, thread.id)
      end

      assert owed(actor) ==
               sorted([
                 record(actor, room, row, @session, 0),
                 record(actor, other, row, @session, 0)
               ])
    end

    test "a forget the thread moved past meanwhile records and clears nothing",
         %{actor: actor, room: room, row: row} do
      held!(actor, room, row, "aqua", @session, 1)
      turn = running!(actor, room, brain_row!(actor))

      assert {:ok, 0} =
               TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

      assert {:ok, %{brain_session: @session, brain_generation: 1}} = Threads.get(actor, room.id)
      assert owed(actor) == []
    end
  end
end
