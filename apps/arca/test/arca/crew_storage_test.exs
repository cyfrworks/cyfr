# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CrewStorageTest do
  @moduledoc """
  The crew's rows and records: a request is accepted with the outbox
  record that delivers it; a turn a delivered request opens stores its
  reply address and its sender, and every terminal write of it records
  one reply naming every request delivered into it; a reply answers the
  requests it names in its own
  acceptance, where the consumer's receipt lands too or nothing does.
  A steer is whatever anyone but the turn's agent wrote into it. One
  child thread stands per member per room, and a retired one admits
  nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, room} = Arca.Test.Days.thread(actor)
    {:ok, actor: actor, room: room}
  end

  defp root!(actor, turn_id) do
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
          reference: "agent:local.planner",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn_id,
          origin: :interactive
        },
        reservation: %{budget_id: budget_id, cap: 4},
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    %{execution: execution, attempt: attempt, budget_id: budget_id}
  end

  defp start!(actor, turn) do
    root = root!(actor, turn.id)

    {:ok, started} =
      TurnStorage.start(actor, turn.id, %{
        root_execution_id: root.execution.id,
        attempt: root.attempt.attempt,
        budget_id: root.budget_id,
        recovery_limit: 3,
        fence: turn.fence
      })

    started
  end

  defp request!(actor, room, member, task, sent_by \\ "person") do
    {:ok, %{message: row}} =
      TurnStorage.accept_message(actor, room.id, %{
        message: %{
          author: if(sent_by == "person", do: actor.user_id, else: "aqua"),
          sent_by: sent_by,
          addressee: member,
          status: "pending",
          content: task
        },
        request: %{
          member: member,
          task: task,
          tools: nil,
          options: %{},
          person_id: actor.user_id,
          origin: :interactive
        }
      })

    row
  end

  # A request delivered into the member's child thread, opening its turn.
  defp delivered!(actor, room, child, request) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, child.id, %{
        message: %{
          author: actor.user_id,
          sent_by: request.sent_by,
          addressee: child.agent,
          content: request.content,
          payload: %{"request_id" => request.id}
        },
        turn: %{agent: child.agent, requested_by: actor.user_id, origin: :interactive},
        reply_address: %{asking_thread_id: room.id, request_id: request.id}
      })

    turn
  end

  defp replies(actor) do
    {:ok, records} = Arca.Outbox.pending(actor, "crew_delivery", "crew_reply")
    records
  end

  defp model_step!(actor, turn, key) do
    {:ok, step} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "model",
        idempotency_key: key,
        fence: turn.fence
      })

    step
  end

  describe "requests" do
    test "a request is accepted with its delivery's record, and a retired child thread admits nothing",
         %{actor: actor, room: room} do
      request = request!(actor, room, "planner", "plan it")

      assert {:ok, [record]} = Arca.Outbox.pending(actor, "crew_delivery", "crew_request")
      assert record.source_kind == "message" and record.source_id == request.id

      assert %{
               "room_thread_id" => room_id,
               "request_id" => request_id,
               "member" => "planner",
               "task" => "plan it",
               "options" => %{},
               "origin" => "interactive"
             } = record.snapshot

      assert room_id == room.id and request_id == request.id

      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      {:ok, _} = Threads.retire(actor, child.id)

      assert {:error, :thread_retired} =
               TurnStorage.accept_message(actor, child.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "late"}
               })

      assert Threads.messages(actor, child.id) == []
    end

    test "a row that names no sender is refused, with nothing written", %{
      actor: actor,
      room: room
    } do
      assert {:error, {:invalid, %{sent_by: _}}} =
               TurnStorage.accept_message(actor, room.id, %{
                 message: %{author: actor.user_id, content: "who said this?"}
               })

      assert {:error, {:invalid, %{sent_by: _}}} =
               Threads.append(actor, room.id, %{author: actor.user_id, content: "or this?"})

      assert Threads.messages(actor, room.id) == []
    end
  end

  describe "replies" do
    test "a delivered turn stores its address and sender, and its completion records one reply for every request delivered into it",
         %{actor: actor, room: room} do
      first = request!(actor, room, "planner", "first")
      also = request!(actor, room, "planner", "also")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

      turn = delivered!(actor, room, child, first)
      assert %{sent_by: "person", asking_thread_id: asking, request_id: request_id} = turn
      assert asking == room.id and request_id == first.id
      turn = start!(actor, turn)

      {:ok, _} =
        TurnStorage.accept_message(actor, child.id, %{
          message: %{
            author: actor.user_id,
            sent_by: "person",
            addressee: "planner",
            content: "also",
            payload: %{"request_id" => also.id}
          },
          steer_turn_id: turn.id
        })

      assert TurnStorage.steer_pending?(actor, turn.id)
      {:ok, [_steer]} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
      step = model_step!(actor, turn, "model:1")

      {:ok, _} =
        TurnStorage.commit_events(
          actor,
          %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}},
          %{
            events: [
              {:text, %{text: "Both done."}},
              {:usage,
               %{"models" => [%{"model" => "m", "counts" => %{}}], "accounting" => "complete"}},
              {:stop, "end_turn"}
            ],
            position: {:step, step.id}
          }
        )

      assert replies(actor) == []

      {:ok, ended} =
        TurnStorage.finish(actor, turn.id, "completed", %{
          fence: turn.fence,
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1
        })

      assert [record] = replies(actor)
      assert record.source_kind == "turn" and record.source_id == turn.id
      assert record.source_revision == DateTime.to_iso8601(ended.ended_at)

      assert %{
               "asking_thread_id" => ^asking,
               "request_ids" => ids,
               "member" => "planner",
               "outcome" => "done",
               "text" => "Both done.",
               "truncated" => false,
               "origin" => "interactive"
             } = record.snapshot

      assert ids == [first.id, also.id]
    end

    test "every other end records its outcome with the error that ended it", %{
      actor: actor,
      room: room
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

      for {status, outcome} <- [
            {"failed", "failed"},
            {"cancelled", "cancelled"},
            {"uncertain", "uncertain"}
          ] do
        request = request!(actor, room, "planner", status)
        turn = delivered!(actor, room, child, request)

        {:ok, _} =
          TurnStorage.finish(actor, turn.id, status, %{fence: turn.fence, error: "it #{status}"})

        record = Enum.find(replies(actor), &(&1.source_id == turn.id))
        assert %{"outcome" => ^outcome, "request_ids" => [id]} = record.snapshot
        assert record.snapshot["text"] == "it #{status}"
        assert id == request.id
      end

      # A turn of the person's own, with no reply address, records none.
      {:ok, %{turn: own}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "hi"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      {:ok, _} = TurnStorage.finish(actor, own.id, "cancelled", %{fence: own.fence})
      refute Enum.any?(replies(actor), &(&1.source_id == own.id))
    end

    test "a reply answers the requests it names that wait on its sender, in its acceptance",
         %{actor: actor, room: room} do
      first = request!(actor, room, "planner", "one", "aqua")
      second = request!(actor, room, "planner", "two", "aqua")
      other = request!(actor, room, "builder", "three", "aqua")

      {:ok, %{message: reply}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{
            author: "aqua",
            sent_by: "planner",
            addressee: "aqua",
            reply_to: first.id,
            outcome: "done",
            content: "both"
          },
          answers: [first.id, second.id, other.id]
        })

      for request <- [first, second] do
        assert {:ok, %{status: "answered", resolved_by: by}} =
                 Threads.get_message(actor, request.id)

        assert by == reply.id
      end

      assert {:ok, %{status: "pending", resolved_by: nil}} = Threads.get_message(actor, other.id)
      assert [%{id: id}] = Threads.pending_requests(actor, thread_id: room.id)
      assert id == other.id
    end
  end

  describe "the end of a member's work" do
    test "the person's stop of a member's thread ends each job there with the request it " <>
           "answers: each reply is recorded and lands as a row that opens no turn",
         %{actor: actor, room: room} do
      first = request!(actor, room, "planner", "first", "aqua")
      second = request!(actor, room, "planner", "second", "aqua")
      later = request!(actor, room, "planner", "later", "aqua")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      running = start!(actor, delivered!(actor, room, child, first))
      queued = delivered!(actor, room, child, second)

      assert {:ok, %{cancelled: cancelled}} =
               TurnStorage.stop_work(actor, child.id, %{
                 error: "the person stopped it",
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1
               })

      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([running.id, queued.id])

      for {turn, request} <- [{running, first}, {queued, second}] do
        assert {:ok, %{status: "cancelled"}} = TurnStorage.get(actor, turn.id)
        assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
        [record] = Enum.filter(replies(actor), &(&1.source_id == turn.id))

        assert %{
                 "outcome" => "cancelled",
                 "text" => "the person stopped it",
                 "request_ids" => ids
               } =
                 record.snapshot

        assert ids == [request.id]

        # The reply as its delivery lands it, waking Aqua as every reply
        # asks: a row, and no turn.
        assert {:ok, %{message: row, turn: nil}} =
                 TurnStorage.accept_message(actor, room.id, %{
                   message: %{
                     author: "aqua",
                     sent_by: "planner",
                     addressee: "aqua",
                     reply_to: request.id,
                     outcome: "cancelled",
                     content: "the person stopped it"
                   },
                   answers: [request.id],
                   turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
                 })

        assert row.reply_to == request.id
        assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
      end

      assert {:ok, []} = TurnStorage.open_turns(actor, room.id)
      assert {:ok, []} = TurnStorage.open_turns(actor, child.id)

      # A request not yet delivered is no job of the thread's: it still
      # waits, and its delivery opens its turn.
      assert {:ok, %{status: "pending"}} = Threads.get_message(actor, later.id)
      assert %{status: "accepted"} = delivered!(actor, room, child, later)
    end

    test "the person's stop of a member's thread ends only its open jobs, expires only what they " <>
           "answer that still waits, a steered request with them, and a stop refused writes nothing",
         %{actor: actor, room: room} do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      earlier = request!(actor, room, "planner", "earlier", "aqua")
      terminal = delivered!(actor, room, child, earlier)

      assert {:ok, terminal} =
               TurnStorage.finish(actor, terminal.id, "cancelled", %{fence: terminal.fence})

      opening = request!(actor, room, "planner", "opening", "aqua")
      turn = start!(actor, delivered!(actor, room, child, opening))
      steered = request!(actor, room, "planner", "steered", "aqua")

      assert {:ok, _} =
               TurnStorage.accept_message(actor, child.id, %{
                 message: %{
                   author: "aqua",
                   sent_by: "aqua",
                   addressee: "planner",
                   content: steered.content,
                   payload: %{"request_id" => steered.id}
                 },
                 steer_turn_id: turn.id
               })

      assert {:ok, _} =
               TurnStorage.accept_message(actor, room.id, %{
                 message: %{
                   author: "aqua",
                   sent_by: "planner",
                   addressee: "aqua",
                   reply_to: opening.id,
                   outcome: "done",
                   content: "Answered."
                 },
                 answers: [opening.id]
               })

      assert {:ok, %{status: "answered"} = answered} = Threads.get_message(actor, opening.id)
      assert {:ok, pending} = Threads.get_message(actor, steered.id)

      assert {:error, :not_standing} =
               TurnStorage.stop_work(actor, child.id, %{
                 grant: :stored,
                 verify: fn _ -> {:error, :not_standing} end
               })

      assert TurnStorage.get(actor, turn.id) == {:ok, turn}
      assert Threads.get_message(actor, steered.id) == {:ok, pending}

      assert {:ok, %{cancelled: [%{turn_id: id}]}} =
               TurnStorage.stop_work(actor, child.id, Map.new(Arca.Test.Actor.stored()))

      assert id == turn.id

      assert {:ok, %{status: "expired", resolved_at: at} = expired} =
               Threads.get_message(actor, steered.id)

      assert expired == %{pending | status: "expired", resolved_at: at}
      assert Threads.get_message(actor, opening.id) == {:ok, answered}
      assert Threads.get_message(actor, earlier.id) == {:ok, earlier}
      assert TurnStorage.get(actor, terminal.id) == {:ok, terminal}

      assert {:ok, %{cancelled: []}} =
               TurnStorage.stop_work(actor, child.id, Map.new(Arca.Test.Actor.stored()))

      assert Threads.get_message(actor, steered.id) == {:ok, expired}

      assert {:ok, ended} = TurnStorage.get(actor, turn.id)
      assert ended.status == "cancelled"
      assert ended.fence == turn.fence + 1
      assert ended.error == nil
      assert %DateTime{} = ended.ended_at
      assert ended.active_ms >= turn.active_ms

      assert Map.drop(ended, [:status, :fence, :ended_at, :active_ms]) ==
               Map.drop(turn, [:status, :fence, :ended_at, :active_ms])
    end

    test "a job delivered while the stop chose its turns is ended with its request",
         %{actor: actor, room: room} do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      first = request!(actor, room, "planner", "already delivered", "aqua")
      working = start!(actor, delivered!(actor, room, child, first))
      request = request!(actor, room, "planner", "delivered during scan", "aqua")

      on_stop_scan(fn ->
        turn = delivered!(actor, room, child, request)
        send(self(), {:delivered_during_stop, turn.id})
      end)

      assert {:ok, %{cancelled: cancelled}} =
               TurnStorage.stop_work(actor, child.id, Map.new(Arca.Test.Actor.stored()))

      assert_received {:delivered_during_stop, id}
      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([id, working.id])
      assert {:ok, %{status: "cancelled"}} = TurnStorage.get(actor, id)
      assert {:ok, %{status: "expired"}} = Threads.get_message(actor, request.id)
    end

    test "a job that ends while the stop chose its turns keeps its request for its own answer",
         %{actor: actor, room: room} do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      request = request!(actor, room, "planner", "complete during scan", "aqua")
      turn = delivered!(actor, room, child, request)

      on_stop_scan(fn ->
        {:ok, _} =
          TurnStorage.finish(actor, turn.id, "cancelled", %{fence: turn.fence, error: "server"})
      end)

      assert {:ok, %{cancelled: []}} = TurnStorage.stop_work(actor, child.id, %{})
      assert {:ok, %{status: "cancelled", error: "server"}} = TurnStorage.get(actor, turn.id)
      assert Threads.get_message(actor, request.id) == {:ok, request}
      assert [%{snapshot: %{"text" => "server", "outcome" => "cancelled"}}] = replies(actor)

      assert {:ok, %{turn: %{status: "accepted"}}} =
               TurnStorage.accept_message(actor, room.id, %{
                 message: %{
                   author: "aqua",
                   sent_by: "planner",
                   addressee: "aqua",
                   reply_to: request.id,
                   outcome: "cancelled",
                   content: "server"
                 },
                 answers: [request.id],
                 turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
               })
    end

    # Runs `work` once, in this process, right after the stop reads which
    # turns are open (its query joins the threads by `parent_id`); the
    # handler is detached after the case and keeps nothing once it ran.
    defp on_stop_scan(work) do
      handler = {:stop_scan, make_ref()}
      Process.put(handler, work)
      on_exit(fn -> :telemetry.detach(handler) end)

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.after_stop_scan/4, handler)
    end

    def after_stop_scan(
          _event,
          _measurements,
          %{source: "turns", query: "SELECT " <> query},
          handler
        ) do
      if String.contains?(query, ~s("parent_id")) do
        if work = Process.delete(handler), do: work.()
      end
    end

    def after_stop_scan(_event, _measurements, _meta, _handler), do: :ok

    test "a reply is recorded under the identity of the request it answers, a damaged child row notwithstanding",
         %{actor: actor, room: room} do
      request = request!(actor, room, "planner", "go")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = delivered!(actor, room, child, request)

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [origin: "hand-edited", requested_by: "usr_someone_else"]
        )

      {:ok, _} = TurnStorage.finish(actor, turn.id, "cancelled", %{fence: turn.fence})
      [record] = Enum.filter(replies(actor), &(&1.source_id == turn.id))

      assert %{"outcome" => "cancelled", "origin" => "interactive", "person_id" => person} =
               record.snapshot

      assert person == actor.user_id
    end

    test "a takeover refuses a turn of a retired thread", %{actor: actor, room: room} do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = start!(actor, delivered!(actor, room, child, request!(actor, room, "planner", "go")))

      # Retired around the turn, as a write that never ran its cancel would
      # leave it.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^child.id),
          set: [retired_at: DateTime.utc_now()]
        )

      assert {:error, :thread_retired} =
               TurnStorage.takeover(actor, turn.id, %{
                 fence: turn.fence,
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1
               })
    end

    test "a turn accepted while its thread was retired is refused its claim", %{
      actor: actor,
      room: room
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = delivered!(actor, room, child, request!(actor, room, "planner", "go"))

      # Retired after the turn's acceptance and before its start, as a
      # retirement whose scan ran ahead of that acceptance leaves it.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^child.id),
          set: [retired_at: DateTime.utc_now()]
        )

      root = root!(actor, turn.id)

      assert {:error, :thread_retired} =
               TurnStorage.start(actor, turn.id, %{
                 root_execution_id: root.execution.id,
                 attempt: root.attempt.attempt,
                 budget_id: root.budget_id,
                 recovery_limit: 3,
                 fence: turn.fence
               })

      assert {:ok, %{active_turn_id: nil}} = Threads.get(actor, child.id)
    end

    test "deleting a room cancels its children's open turns and deletes them, writing no reply",
         %{actor: actor, room: room} do
      {:ok, planner} = Threads.crew_thread(actor, room.id, "planner")
      {:ok, builder} = Threads.crew_thread(actor, room.id, "builder")
      waiting = delivered!(actor, room, planner, request!(actor, room, "planner", "plan"))

      working =
        actor
        |> delivered!(room, builder, request!(actor, room, "builder", "build"))
        |> then(&start!(actor, &1))

      assert {:ok, %{cancelled: cancelled}} =
               Threads.delete(actor, room.id, %{grant: :stored, verify: &Arca.Test.Actor.admits/1})

      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([waiting.id, working.id])

      for gone <- [room, planner, builder] do
        assert {:error, :not_found} = Threads.get(actor, gone.id)
        assert Threads.messages(actor, gone.id) == []
      end

      assert replies(actor) == []

      assert %{status: "cancelled"} =
               Arca.Repo.get!(Arca.Schemas.Execution, working.root_execution_id)
    end
  end

  describe "deleting a room" do
    test "a deleted room answers its surviving asker but not the asks made inside it",
         %{actor: actor, room: room} do
      {:ok, outside} = Arca.Test.Days.thread(actor)
      request = request!(actor, outside, "aqua", "work", "aqua")

      {:ok, %{turn: own}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{
            author: "aqua",
            sent_by: "aqua",
            content: request.content,
            payload: %{"request_id" => request.id}
          },
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive},
          reply_address: %{asking_thread_id: outside.id, request_id: request.id}
        })

      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      nested = delivered!(actor, room, child, request!(actor, room, "planner", "plan"))
      outside_before = Threads.get(actor, outside.id)

      assert {:ok, %{cancelled: cancelled}} = Threads.delete(actor, room.id)
      assert Enum.sort(Enum.map(cancelled, & &1.turn_id)) == Enum.sort([own.id, nested.id])
      assert Threads.get(actor, outside.id) == outside_before
      assert {:error, :not_found} = Threads.get(actor, room.id)
      assert {:error, :not_found} = Threads.get(actor, child.id)
      assert [reply] = replies(actor)
      assert reply.snapshot["asking_thread_id"] == outside.id
      assert reply.snapshot["request_ids"] == [request.id]
      assert reply.snapshot["outcome"] == "cancelled"
      assert reply.snapshot["text"] == "the room was deleted"
    end

    test "decides before any byte goes: a refusal keeps every blob",
         %{actor: actor, room: room} do
      {:ok, planner} = Threads.crew_thread(actor, room.id, "planner")

      running =
        actor
        |> delivered!(room, planner, request!(actor, room, "planner", "plan"))
        |> then(&start!(actor, &1))

      blobs = for thread <- [room, planner], do: Threads.blob_root(thread.id) ++ ["msg", "a.txt"]
      for blob <- blobs, do: :ok = Arca.put(actor, blob, "bytes")

      # The child's running turn ends only under its root's grant: a
      # deletion that carries none is refused in its transaction.
      assert {:error, :missing_grant} = Threads.delete(actor, room.id)
      for blob <- blobs, do: assert(Arca.exists?(actor, blob))

      assert {:ok, %{cancelled: [%{turn_id: turn_id}]}} =
               Threads.delete(actor, room.id, %{grant: :stored, verify: &Arca.Test.Actor.admits/1})

      assert turn_id == running.id

      for thread <- [room, planner],
          do: assert({:error, :not_found} = Threads.get(actor, thread.id))

      for blob <- blobs, do: refute(Arca.exists?(actor, blob))
    end
  end

  describe "the consumer's receipt" do
    test "lands with the row it delivers, and a claim lost writes neither", %{
      actor: actor,
      room: room
    } do
      request = request!(actor, room, "planner", "go")
      {:ok, [record]} = Arca.Outbox.pending(actor, "crew_delivery", "crew_request")
      {:ok, claim} = Arca.JobClaims.claim("crew_delivery", actor.athanor_id, "boot_a", 60_000)
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")

      receipt =
        record
        |> Prima.OutboxRecord.source()
        |> Map.merge(%{consumer: "crew_delivery", outcome: "applied"})

      delivery = fn ->
        TurnStorage.accept_message(actor, child.id, %{
          message: %{
            author: actor.user_id,
            sent_by: "person",
            addressee: "planner",
            content: request.content,
            payload: %{"request_id" => request.id}
          },
          receipt: %{receipt: receipt, claim: claim, slot: slot}
        })
      end

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.JobClaim,
            where: c.kind == "crew_delivery" and c.key == ^actor.athanor_id
          ),
          set: [owner: "boot_peer"],
          inc: [fence: 1]
        )

      assert {:error, :taken} = delivery.()
      assert Threads.messages(actor, child.id) == []
      assert {:ok, [_still]} = Arca.Outbox.pending(actor, "crew_delivery", "crew_request")

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.JobClaim,
            where: c.kind == "crew_delivery" and c.key == ^actor.athanor_id
          ),
          set: [owner: "boot_a", fence: claim.fence]
        )

      assert {:ok, %{message: _row}} = delivery.()
      assert {:ok, []} = Arca.Outbox.pending(actor, "crew_delivery", "crew_request")
      assert {:error, :receipted} = delivery.()
      assert [_one] = Threads.messages(actor, child.id)
    end
  end

  describe "steering and the projection" do
    test "a steer is what anyone but the turn's agent wrote into it past its boundary", %{
      actor: actor,
      room: room
    } do
      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      turn = start!(actor, turn)

      {:ok, own} =
        TurnStorage.append_turn_row(actor, turn.id, %{
          author: "system",
          kind: "system",
          content: "a note of the turn's own",
          fence: turn.fence
        })

      assert own.sent_by == "aqua"
      refute TurnStorage.steer_pending?(actor, turn.id)
      assert {:ok, rows} = TurnStorage.projection(actor, turn.id)
      assert own.id in Enum.map(rows, & &1.id)

      {:ok, %{message: reply}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{author: "aqua", sent_by: "planner", content: "a reply"},
          steer_turn_id: turn.id
        })

      assert TurnStorage.steer_pending?(actor, turn.id)
      assert {:ok, rows} = TurnStorage.projection(actor, turn.id)
      refute reply.id in Enum.map(rows, & &1.id)

      assert {:ok, [%{id: drained}]} =
               TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})

      assert drained == reply.id
    end

    test "a step joins the read threads of the member turn whose reply its rows carry, across threads",
         %{actor: actor, room: room} do
      request = request!(actor, room, "planner", "read the news")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      member = actor |> delivered!(room, child, request) |> then(&start!(actor, &1))
      :ok = TurnStorage.join_threads(actor, member.id, ["thr_news"], %{fence: member.fence})

      {:ok, %{turn: soul}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{
            author: "aqua",
            sent_by: "planner",
            addressee: "aqua",
            reply_to: request.id,
            outcome: "done",
            content: "The news says x.",
            payload: %{"from_turn" => member.id}
          },
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      soul = start!(actor, soul)

      {:ok, _} =
        TurnStorage.put_step(actor, soul.id, %{
          kind: "model",
          idempotency_key: "model:1",
          threads_from: [member.id],
          fence: soul.fence
        })

      assert Arca.Repo.get!(Arca.Schemas.Turn, soul.id).read_threads == ~s(["thr_news"])
    end

    # A home reset moved the thread on while the turn's program was at work:
    # the turn's forget clears nothing, and answers the generation the turn
    # read, under which nothing it answers with is kept.
    test "a turn's forget under a generation the thread has left clears nothing", %{
      actor: actor,
      room: room
    } do
      turn = running!(actor, room)

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^room.id),
          inc: [brain_generation: 1]
        )

      keep_session!(room, "session-since")

      assert {:ok, 0} =
               TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence, generation: 0})

      assert {:ok, %{brain_session: "session-since", brain_generation: 1}} =
               Threads.get(actor, room.id)
    end

    test "a turn's forget is refused without its fence or its generation, and to another athanor",
         %{actor: actor, room: room} do
      turn = running!(actor, room)
      keep_session!(room, "kept-session")
      elsewhere = Prima.Actor.in_athanor("ath_other")

      assert {:error, :generation_required} =
               TurnStorage.forget_session(actor, turn.id, %{fence: turn.fence})

      assert {:error, :fence_required} =
               TurnStorage.forget_session(actor, turn.id, %{generation: 0})

      assert {:error, :superseded} =
               TurnStorage.forget_session(actor, turn.id, %{
                 fence: turn.fence + 1,
                 generation: 0
               })

      assert {:error, :superseded} =
               TurnStorage.forget_session(elsewhere, turn.id, %{
                 fence: turn.fence,
                 generation: 0
               })

      assert {:ok, %{brain_session: "kept-session", brain_generation: 0}} =
               Threads.get(actor, room.id)
    end
  end

  # The session `thread` keeps, as an earlier turn's answer left it.
  defp keep_session!(thread, session) do
    {1, _} =
      from(t in Arca.Schemas.Thread, where: t.id == ^thread.id)
      |> Arca.Repo.update_all(set: [brain_session: session])
  end

  # A turn of the soul's in `room`, started.
  defp running!(actor, room) do
    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, room.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    start!(actor, turn)
  end

  describe "child threads" do
    test "one stands per member per room; retired ones stay listed, and the next is new", %{
      actor: actor,
      room: room
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      assert %{kind: "crew", agent: "planner", title: "planner", retired_at: nil} = child
      assert child.parent_id == room.id
      assert {:ok, %{id: same}} = Threads.crew_thread(actor, room.id, "planner")
      assert same == child.id

      {:ok, %{id: other}} = Threads.crew_thread(actor, room.id, "builder")
      assert other != child.id

      {:ok, %{thread: retired, cancelled: []}} = Threads.retire(actor, child.id)
      assert retired.retired_at
      assert {:ok, %{thread: ^retired, cancelled: []}} = Threads.retire(actor, child.id)
      {:ok, fresh} = Threads.crew_thread(actor, room.id, "planner")
      assert fresh.id not in [child.id, other]

      assert Enum.map(Threads.children(actor, room.id), & &1.id) == [child.id, other, fresh.id]
      assert {:error, :not_crew} = Threads.retire(actor, room.id)
      assert {:error, :not_a_room} = Threads.crew_thread(actor, fresh.id, "web")
      assert Enum.map(Threads.list(actor, kind: "daily"), & &1.id) == [room.id]
    end

    test "a workspace thread is a room as a daily one is, and another athanor's room is none", %{
      actor: actor,
      room: room
    } do
      workspace =
        %Arca.Schemas.Thread{}
        |> Arca.Schemas.Thread.changeset(%{
          id: Prima.UUID7.generate_id("thread"),
          athanor_id: actor.athanor_id,
          kind: "workspace",
          workspace_state: "open",
          title: "Book the trip",
          created_by: "system"
        })
        |> Arca.Repo.insert!()

      {:ok, child} = Threads.crew_thread(actor, workspace.id, "planner")
      assert %{kind: "crew", agent: "planner", parent_id: parent} = child
      assert parent == workspace.id
      assert {:error, :not_a_room} = Threads.crew_thread(actor, child.id, "builder")

      elsewhere = Prima.Actor.in_athanor("ath_other")

      for theirs <- [room.id, workspace.id] do
        assert {:error, :not_found} = Threads.crew_thread(elsewhere, theirs, "planner")
        assert Threads.children(elsewhere, theirs) == []
      end

      # The workspace's member thread goes with it.
      assert {:ok, %{cancelled: []}} = Threads.delete(actor, workspace.id)
      assert {:error, :not_found} = Threads.get(actor, child.id)
    end

    test "a home's forget reaches the threads that store its row, in the actor's athanor alone",
         %{actor: actor, room: room} do
      {:ok, planner} = Threads.crew_thread(actor, room.id, "planner")
      {:ok, builder} = Threads.crew_thread(actor, room.id, "builder")

      elsewhere = Prima.Actor.in_athanor("ath_other")
      {:ok, theirs} = Arca.Test.Days.thread(elsewhere)

      # Another athanor's thread that names the same row as well. No row of
      # that id stands here, so a forget owes no removal.
      for {thread, row, session} <- [
            {planner, "mcp_home", "s-planner"},
            {builder, "mcp_other", "s-builder"},
            {theirs, "mcp_home", "s-x"}
          ] do
        {1, _} =
          from(t in Arca.Schemas.Thread, where: t.id == ^thread.id)
          |> Arca.Repo.update_all(
            set: [brain_session: session, brain_progress: Jason.encode!(%{"row" => row})]
          )
      end

      assert {:ok, _forgotten} = Threads.forget_sessions(actor, "mcp_home")
      assert {:ok, %{brain_session: nil, brain_generation: 1}} = Threads.get(actor, planner.id)

      assert {:ok, %{brain_session: "s-builder", brain_generation: 0}} =
               Threads.get(actor, builder.id)

      assert {:ok, %{brain_session: "s-x", brain_generation: 0}} =
               Threads.get(elsewhere, theirs.id)
    end
  end
end
