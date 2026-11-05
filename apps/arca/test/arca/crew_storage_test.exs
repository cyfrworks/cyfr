# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CrewStorageTest.PausingDelete do
  @moduledoc false
  use Arca.Storage.TestDouble

  # The first thread tree this process deletes runs the test's hook
  # first: what a child does the moment a deletion's bytes start to go.
  def delete_tree(actor, ["threads", _id] = path) do
    if hook = Process.delete(:on_blob_delete), do: hook.()
    Arca.Adapters.Local.delete_tree(actor, path)
  end

  def delete_tree(actor, path), do: Arca.Adapters.Local.delete_tree(actor, path)
end

defmodule Arca.CrewStorageTest do
  @moduledoc """
  The crew's rows and records: a request is accepted with the outbox
  record that delivers it; a turn a delivered request opens stores its
  reply address and its sender, and every terminal write of it records
  one reply naming every request delivered into it, as a card it opens
  records a notice; a reply answers the requests it names in its own
  acceptance, where the consumer's receipt lands too or nothing does.
  A steer is whatever anyone but the turn's agent wrote into it. One
  child thread stands per member per room, and an archived one admits
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
    {:ok, room} = Threads.create(actor)
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
    test "a request is accepted with its delivery's record, and an archived child thread admits nothing",
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
      {:ok, _} = Threads.archive(actor, child.id)

      assert {:error, :thread_archived} =
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
        TurnStorage.record_response(actor, turn.id, step.id, %{
          fence: turn.fence,
          text: "Both done.",
          usage: %{},
          stop_reason: "end_turn",
          tool_calls: []
        })

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

    test "a card in a delivered turn records a needs_you reply with the card's text, in its own transaction",
         %{actor: actor, room: room} do
      request = request!(actor, room, "planner", "keep it")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = actor |> delivered!(room, child, request) |> then(&start!(actor, &1))
      step = model_step!(actor, turn, "model:1")

      {:ok, %{calls: [%{step: call}]}} =
        TurnStorage.record_response(actor, turn.id, step.id, %{
          fence: turn.fence,
          text: nil,
          usage: %{},
          stop_reason: "tool_call",
          tool_calls: [
            %{
              tool_call_id: "k1",
              name: "notes",
              tool: "notes",
              action: "keep",
              arguments: %{},
              kind: "write",
              idempotency_key: "call:k1",
              proposal_digest: "sha256:k1"
            }
          ]
        })

      {:ok, _} =
        TurnStorage.open_approval(actor, call.id, %{
          proposal_digest: "sha256:k1",
          card: %{content: "Keep the note plan?"},
          fence: turn.fence
        })

      assert [record] = replies(actor)

      assert %{"outcome" => "needs_you", "text" => "Keep the note plan?", "request_ids" => [id]} =
               record.snapshot

      assert id == request.id
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

    test "recovery refuses a turn of an archived thread", %{actor: actor, room: room} do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = delivered!(actor, room, child, request!(actor, room, "planner", "go"))

      # Archived around the turn, as a write that never ran its cancel would
      # leave it.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^child.id),
          set: [archived_at: DateTime.utc_now()]
        )

      assert {:error, :thread_archived} =
               TurnStorage.recover(actor, turn.id, %{
                 fence: turn.fence,
                 recovery_limit: 3,
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1
               })
    end

    test "a turn accepted while its thread was archived is refused its claim", %{
      actor: actor,
      room: room
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      turn = delivered!(actor, room, child, request!(actor, room, "planner", "go"))

      # Archived after the turn's acceptance and before its start, as an
      # archive whose scan ran ahead of that acceptance leaves it.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^child.id),
          set: [archived_at: DateTime.utc_now()]
        )

      root = root!(actor, turn.id)

      assert {:error, :thread_archived} =
               TurnStorage.start(actor, turn.id, %{
                 root_execution_id: root.execution.id,
                 attempt: root.attempt.attempt,
                 budget_id: root.budget_id,
                 recovery_limit: 3,
                 fence: turn.fence
               })

      assert {:ok, %{active_turn_id: nil}} = Threads.get(actor, child.id)
    end

    test "deleting a room cancels its children's open turns and deletes them, writing no reply, and waits for a card",
         %{actor: actor, room: room} do
      {:ok, planner} = Threads.crew_thread(actor, room.id, "planner")
      {:ok, builder} = Threads.crew_thread(actor, room.id, "builder")
      waiting = delivered!(actor, room, planner, request!(actor, room, "planner", "plan"))

      working =
        actor
        |> delivered!(room, builder, request!(actor, room, "builder", "build"))
        |> then(&start!(actor, &1))

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^waiting.id),
          set: [status: "paused", paused_reason: "approval"]
        )

      assert {:error, {:child_awaits_card, "planner"}} = Threads.delete(actor, room.id)
      assert {:ok, _} = Threads.get(actor, planner.id)

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^waiting.id),
          set: [status: "accepted", paused_reason: nil]
        )

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
    test "decides before any byte goes: a refusal keeps every blob, and a card opened as the bytes go comes too late to refuse",
         %{actor: actor, room: room} do
      {:ok, planner} = Threads.crew_thread(actor, room.id, "planner")
      waiting = delivered!(actor, room, planner, request!(actor, room, "planner", "plan"))
      blobs = for thread <- [room, planner], do: Threads.blob_root(thread.id) ++ ["msg", "a.txt"]
      for blob <- blobs, do: :ok = Arca.put(actor, blob, "bytes")

      pause = fn status, reason ->
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^waiting.id),
          set: [status: status, paused_reason: reason]
        )
      end

      {1, _} = pause.("paused", "approval")
      assert {:error, {:child_awaits_card, "planner"}} = Threads.delete(actor, room.id)
      for blob <- blobs, do: assert(Arca.exists?(actor, blob))
      {1, _} = pause.("accepted", nil)

      # The child pauses on a card when the first bytes would go: after the
      # commit that decided, so the deletion stands whole.
      Process.put(:on_blob_delete, fn -> pause.("paused", "approval") end)

      assert {:ok, %{cancelled: [%{turn_id: turn_id}]}} =
               Prima.Test.Env.with_app_env(
                 :arca,
                 :storage_adapter,
                 Arca.CrewStorageTest.PausingDelete,
                 fn ->
                   Threads.delete(actor, room.id, %{
                     grant: :stored,
                     verify: &Arca.Test.Actor.admits/1
                   })
                 end
               )

      assert turn_id == waiting.id
      assert Process.get(:on_blob_delete) == nil

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

    test "a step joins the sources of the member turn whose reply its rows carry, across threads",
         %{actor: actor, room: room} do
      request = request!(actor, room, "planner", "read the news")
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      member = actor |> delivered!(room, child, request) |> then(&start!(actor, &1))
      news = Prima.Source.outside("news.example")
      :ok = TurnStorage.join_sources(actor, member.id, [news], %{fence: member.fence})

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
          sources_from: [member.id],
          fence: soul.fence
        })

      assert news in Prima.Source.decode(Arca.Repo.get!(Arca.Schemas.Turn, soul.id).sources)
    end

    test "a response's session is kept on the thread for its next request", %{
      actor: actor,
      room: room
    } do
      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, room.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      turn = start!(actor, turn)
      step = model_step!(actor, turn, "model:1")

      {:ok, _} =
        TurnStorage.record_response(actor, turn.id, step.id, %{
          fence: turn.fence,
          text: "hi",
          usage: %{},
          stop_reason: "end_turn",
          session: "brain-session-1",
          tool_calls: []
        })

      assert {:ok, %{brain_session: "brain-session-1"}} = Threads.get(actor, room.id)
    end
  end

  describe "child threads" do
    test "one stands per member per room; archived ones stay listed, and the next is new", %{
      actor: actor,
      room: room
    } do
      {:ok, child} = Threads.crew_thread(actor, room.id, "planner")
      assert %{kind: "crew", agent: "planner", title: "planner", archived_at: nil} = child
      assert child.parent_id == room.id
      assert {:ok, %{id: same}} = Threads.crew_thread(actor, room.id, "planner")
      assert same == child.id

      {:ok, %{id: other}} = Threads.crew_thread(actor, room.id, "builder")
      assert other != child.id

      {:ok, %{thread: archived, cancelled: []}} = Threads.archive(actor, child.id)
      assert archived.archived_at
      assert {:ok, %{thread: ^archived, cancelled: []}} = Threads.archive(actor, child.id)
      {:ok, fresh} = Threads.crew_thread(actor, room.id, "planner")
      assert fresh.id not in [child.id, other]

      assert Enum.map(Threads.children(actor, room.id), & &1.id) == [child.id, other, fresh.id]
      assert {:error, :not_crew} = Threads.archive(actor, room.id)
      assert {:error, :not_a_room} = Threads.crew_thread(actor, fresh.id, "web")
      assert Enum.map(Threads.list(actor, kind: "own"), & &1.id) == [room.id]
    end
  end
end
