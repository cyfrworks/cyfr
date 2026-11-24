# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnTapeStorageTest do
  @moduledoc """
  The durable turn: acceptance is atomic with the work it opens; a step
  is proposed before its effect and closed with its result; pause,
  resume, finish and takeover move the turn,
  its attempt and its root execution together; the projection reads
  behind a consumption boundary that a queued turn never crosses.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Arca.ExecutionAttempts
  alias Arca.Schemas.Message
  alias Arca.TurnStorage

  import Ecto.Query, only: [from: 2]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, thread} = Arca.Test.Days.thread(actor)
    {:ok, actor: actor, thread: thread}
  end

  # A turn root: a `kind: "turn"` execution with its reservation.
  defp root!(actor, turn_id) do
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
          turn_id: turn_id,
          origin: :interactive
        },
        reservation: %{budget_id: budget_id, cap: 4},
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    %{execution: execution, attempt: attempt, budget_id: budget_id}
  end

  defp accept_turn!(actor, thread, text, opts \\ []) do
    {:ok, %{message: message, turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{
          author: Keyword.get(opts, :author, actor.user_id),
          sent_by: "person",
          content: text,
          client_id: Keyword.get(opts, :client_id)
        },
        turn: %{
          agent: "aqua",
          requested_by: Keyword.get(opts, :author, actor.user_id),
          model: Keyword.get(opts, :model),
          options: %{"room" => nil},
          origin: :interactive
        }
      })

    %{message: message, turn: turn}
  end

  defp start!(actor, turn) do
    root = root!(actor, turn.id)

    {:ok, started} =
      TurnStorage.start(actor, turn.id, %{
        root_execution_id: root.execution.id,
        attempt: root.attempt.attempt,
        budget_id: root.budget_id,
        profile_id: "prof_x",
        consent_id: "consent_x",
        agent_revision_digest: "sha256:rev",
        agent_capability_digest: "sha256:cap",
        recovery_limit: 3,
        fence: turn.fence
      })

    {started, root}
  end

  # `start!/2` with the claim's own arguments in the caller's hands: the
  # consumed sequence it names, and nothing else changed.
  defp start_with(actor, turn, opts) do
    root = root!(actor, turn.id)

    TurnStorage.start(
      actor,
      turn.id,
      Enum.into(opts, %{
        root_execution_id: root.execution.id,
        attempt: root.attempt.attempt,
        budget_id: root.budget_id,
        recovery_limit: 3,
        fence: turn.fence
      })
    )
  end

  defp reread(actor, thread) do
    {:ok, row} = Threads.get(actor, thread.id)
    row
  end

  # One live member of the cell that is not this boot, under a node name
  # nothing else writes: the row's own slot, so the case measures its own
  # delta rather than whatever the suite left in a shared table. The row is
  # the sandbox's and goes with it: a delete on another connection would
  # wait behind the owner's write lock until the owner stops.
  defp peer_member!(lease_ms \\ 60_000) do
    node = "h1-peer-#{System.unique_integer([:positive])}@test"
    owner = "#{node}#boot_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.CellLease, [
        %{
          node: node,
          owner: owner,
          generation: 1,
          fence: 1,
          lease_until: DateTime.add(DateTime.utc_now(), lease_ms, :millisecond),
          taken_at: DateTime.utc_now(),
          release: "0.0.0-test",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

    %{node: node, owner: owner}
  end

  defp execution(id), do: Arca.Repo.get!(Arca.Schemas.Execution, id)

  defp respond!(actor, turn, calls) do
    {:ok, step} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "model",
        idempotency_key: "model:1",
        fence: turn.fence
      })

    asks =
      Enum.map(calls, fn {id, tool, action} ->
        {:ask,
         %{
           kind: "tool",
           tool: tool,
           action: action,
           recovery: "replay_safe",
           child_execution_id: "exec_child_" <> id,
           idempotency_key: "call:#{turn.id}:1:#{id}",
           call: %{
             kind: "tool_call",
             content: "#{tool}.#{action}",
             payload: %{
               "tool_call_id" => id,
               "name" => "#{tool}.#{action}",
               "tool" => tool,
               "action" => action,
               "arguments" => %{"path" => "a.txt"},
               "provider_data" => %{"thought_signature" => "sig-" <> id},
               "kind" => "read",
               "step_id" => step.id
             }
           }
         }}
      end)

    {:ok, recorded} =
      TurnStorage.commit_events(actor, scope(turn), %{
        events:
          [{:text, %{text: "On it."}}] ++
            asks ++
            [{:usage, usage(%{"input_tokens" => 10, "output_tokens" => 3})}, {:stop, "tool_call"}],
        position: {:step, step.id}
      })

    {step, recorded}
  end

  defp scope(turn),
    do: %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}}

  # What a model ran and its counts, as a usage event tells them.
  defp usage(counts),
    do: %{"models" => [%{"model" => "m", "counts" => counts}], "accounting" => "complete"}

  # The turn paused around a launch it handed to a person.
  defp launch_paused!(actor, turn) do
    {:ok, launch} =
      TurnStorage.put_step(actor, turn.id, %{
        kind: "launch",
        idempotency_key: "launch:1",
        fence: turn.fence
      })

    {:ok, paused} =
      TurnStorage.pause(actor, turn.id, %{
        fence: turn.fence,
        reason: "launch",
        launch_step_id: launch.id
      })

    paused
  end

  describe "acceptance" do
    test "room content is a row alone; an addressed message opens its turn atomically", %{
      actor: actor,
      thread: thread
    } do
      assert {:ok, %{message: post, turn: nil}} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "just saying"}
               })

      assert post.seq == 1 and is_nil(post.turn_id)

      %{message: message, turn: turn} =
        accept_turn!(actor, thread, "@aqua do it", client_id: "c-1")

      assert turn.status == "accepted"
      assert turn.message_id == message.id
      assert turn.fence != ""
      assert turn.runner_id == Prima.Boot.id()

      assert {:ok, %{turn_seq: 1, agent: "aqua"}} = Threads.get(actor, thread.id)

      # The same client id is one acceptance: the retry finds it.
      assert {:error, :duplicate_client_id} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{
                   author: actor.user_id,
                   sent_by: "person",
                   content: "@aqua do it",
                   client_id: "c-1"
                 },
                 turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
               })

      assert {:ok, %{message: %{id: mid}, turn: %{id: tid}}} =
               TurnStorage.accepted(actor, thread.id, "c-1")

      assert mid == message.id and tid == turn.id
      assert {:ok, [%{id: ^tid}]} = TurnStorage.open_turns(actor, thread.id)
    end

    test "a steer attaches to the live turn without opening another", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)

      assert {:ok, %{message: steer, turn: %{id: tid}}} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "also this"},
                 steer_turn_id: turn.id
               })

      assert tid == turn.id and steer.turn_id == turn.id
      assert {:ok, [_]} = TurnStorage.open_turns(actor, thread.id)
      assert TurnStorage.steer_pending?(actor, turn.id)
    end

    test "a steer to a turn that has ended is refused and writes no row", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)

      {:ok, _} =
        TurnStorage.finish(actor, turn.id, "completed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: turn.fence
        })

      before = length(Threads.messages(actor, thread.id))

      assert {:error, :turn_over} =
               TurnStorage.accept_message(actor, thread.id, %{
                 message: %{author: actor.user_id, sent_by: "person", content: "too late"},
                 steer_turn_id: turn.id
               })

      assert length(Threads.messages(actor, thread.id)) == before
    end
  end

  describe "start" do
    test "an accepted turn starts once, with its pins and the boundary at its own message", %{
      actor: actor,
      thread: thread
    } do
      {:ok, _} =
        Threads.append(actor, thread.id, %{
          author: actor.user_id,
          sent_by: "person",
          content: "earlier"
        })

      %{message: message, turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, root} = start!(actor, turn)

      assert started.status == "running"
      assert started.root_execution_id == root.execution.id
      assert started.attempt == root.attempt.attempt
      assert started.budget_id == root.budget_id
      assert started.consent_id == "consent_x"
      assert started.window_upto_seq == message.seq

      assert {:error, :not_accepted} =
               TurnStorage.start(actor, turn.id, %{
                 root_execution_id: root.execution.id,
                 fence: turn.fence
               })

      # A superseded fence writes nothing.
      assert {:error, :superseded} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence - 1})

      # A write that names no fence writes nothing either.
      assert {:error, :fence_required} = TurnStorage.pause(actor, turn.id, %{})
    end
  end

  describe "the thread claim" do
    test "starting takes the thread for the turn, and the sequence the caller read decides", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      assert %{active_turn_id: nil, turn_seq: seq} = reread(actor, thread)

      # The consumed sequence the claimant read, and only that one.
      assert {:error, :stale} = start_with(actor, turn, turn_seq: seq + 1)
      assert %{active_turn_id: nil} = reread(actor, thread)

      {started, _root} = start!(actor, turn)
      assert %{active_turn_id: held} = reread(actor, thread)
      assert held == turn.id

      # Another member's turn on the same thread claims nothing while this
      # one holds it: the claim is not something a peer takes over.
      %{turn: second} = accept_turn!(actor, thread, "@aqua again")
      assert {:error, {:held_elsewhere, ^held}} = start_with(actor, second, [])
      assert %{active_turn_id: ^held} = reread(actor, thread)

      # The turn that is over holds nothing.
      {:ok, _} =
        TurnStorage.finish(actor, turn.id, "completed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: started.fence
        })

      assert %{active_turn_id: nil} = reread(actor, thread)

      # And the one behind it may now take the thread.
      {_, _} = start!(actor, second)
      assert %{active_turn_id: taken} = reread(actor, thread)
      assert taken == second.id
    end

    test "a launch pause keeps the claim", %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)
      assert %{active_turn_id: held} = reread(actor, thread)
      assert held == turn.id

      # The pause a launch raises: still this member's work, still its thread.
      paused = launch_paused!(actor, started)
      assert paused.paused_reason == "launch"
      assert %{active_turn_id: ^held} = reread(actor, thread)

      {:ok, _resumed} =
        TurnStorage.resume(actor, turn.id, %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: paused.fence
        })

      assert %{active_turn_id: ^held} = reread(actor, thread)
    end

    test "a turn a live peer holds is not taken over, and no recovery is spent", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)

      # The turn moves to a peer: its boot, and a cell slot of that peer's
      # own that has not lapsed. The slot is keyed by a node name nothing
      # else in the suite writes, and the delta is this turn's alone.
      peer = peer_member!()

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [runner_id: peer.owner]
        )

      before_count = Arca.Repo.get!(Arca.Schemas.Turn, turn.id).recovery_attempts

      assert {:ok, %{turn_id: holder, runner_id: runner, live_peer?: true}} =
               Threads.claim_holder(actor, thread.id)

      assert holder == turn.id
      assert runner == peer.owner

      assert {:error, :held_elsewhere} =
               TurnStorage.takeover(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: started.fence
               })

      after_count = Arca.Repo.get!(Arca.Schemas.Turn, turn.id).recovery_attempts
      assert after_count == before_count

      # Once the peer's slot has lapsed the same turn is taken over, which
      # is what makes the refusal above the liveness of the slot and not the
      # name in the row.
      {1, _} =
        Arca.Repo.update_all(
          from(l in Arca.Schemas.CellLease, where: l.node == ^peer.node),
          set: [lease_until: DateTime.add(DateTime.utc_now(), -60, :second)]
        )

      assert {:ok, %{live_peer?: false}} = Threads.claim_holder(actor, thread.id)

      assert {:ok, taken} =
               TurnStorage.takeover(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: started.fence
               })

      assert taken.recovery_attempts == before_count + 1
    end
  end

  describe "steps" do
    test "a response is committed before any call runs, each call dispatches once and closes with its result",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua read a.txt")
      {turn, root} = start!(actor, turn)

      {model_step, %{said: [text], asks: [%{message: call_row, step: call_step}]}} =
        respond!(actor, turn, [{"call_1", "files", "read"}])

      assert text.kind == "text" and text.turn_id == turn.id
      assert call_row.kind == "tool_call"

      assert %{"provider_data" => %{"thought_signature" => "sig-call_1"}} =
               Threads.payload(call_row)

      assert call_step.dispatch_state == "proposed"
      assert call_step.child_execution_id == "exec_child_call_1"
      assert call_step.recovery == "replay_safe"

      assert {:ok, %{dispatch_state: "closed", outcome: "ok", usage: usage}} =
               TurnStorage.step(actor, model_step.id)

      # A model step's usage is counted as a program's start step's is: one
      # result, by the model it ran.
      assert Jason.decode!(usage) == %{
               "models" => %{"m" => %{"input_tokens" => 10, "output_tokens" => 3}},
               "results" => 1,
               "partial" => 0,
               "unknown" => 0
             }

      assert {:ok, %{dispatch_state: "dispatched", started_at: %DateTime{}}} =
               TurnStorage.dispatch_step(actor, call_step.id, %{
                 fence: turn.fence
               })

      assert {:error, :not_proposed} =
               TurnStorage.dispatch_step(actor, call_step.id, %{
                 fence: turn.fence
               })

      assert {:ok, %{step: closed, result: result}} =
               TurnStorage.close_step(actor, call_step.id, "ok", %{
                 result: %{content: "line 1", payload: %{"tool_call_id" => "call_1"}},
                 execution_id: "exec_child_call_1",
                 fence: turn.fence
               })

      assert closed.outcome == "ok" and closed.result_message_id == result.id
      assert result.kind == "tool_result" and result.author == Message.system_author()

      assert {:error, :not_open} =
               TurnStorage.close_step(actor, call_step.id, "ok", %{
                 fence: turn.fence
               })

      assert {:ok, events} = Arca.ExecutionEvents.since(actor, root.execution.id, 0)

      assert Enum.map(events, & &1.type) ==
               ["execution.started", "turn.started", "model.completed", "step.closed"]
    end

    test "a call serves what the request that proposed it served; an unknown purpose is refused",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua keep it")
      {turn, _root} = start!(actor, turn)

      {:ok, flush} =
        TurnStorage.put_step(actor, turn.id, %{
          kind: "model",
          purpose: "flush",
          fence: turn.fence
        })

      assert {:ok, %{asks: [%{step: call}]}} =
               TurnStorage.commit_events(actor, scope(turn), %{
                 events: [
                   {:ask,
                    %{
                      kind: "tool",
                      tool: "notes",
                      action: "keep",
                      idempotency_key: "call:#{turn.id}:#{flush.id}:n1",
                      call: %{
                        kind: "tool_call",
                        content: "notes",
                        payload: %{
                          "tool_call_id" => "n1",
                          "name" => "notes",
                          "tool" => "notes",
                          "action" => "keep",
                          "step_id" => flush.id
                        }
                      }
                    }}
                 ],
                 position: {:step, flush.id}
               })

      assert call.purpose == "flush"

      assert {:ok, %{purpose: "chat"}} =
               TurnStorage.put_step(actor, turn.id, %{
                 kind: "model",
                 fence: turn.fence
               })

      assert {:error, {:invalid_step_purpose, "summary"}} =
               TurnStorage.put_step(actor, turn.id, %{
                 kind: "model",
                 purpose: "summary",
                 fence: turn.fence
               })
    end

    test "the step barrier binds only a dispatched, current, uncancelled generation", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)
      {_model, %{asks: [%{step: step}]}} = respond!(actor, turn, [{"c", "files", "read"}])

      bind = fn gen, exec ->
        {:ok, n} =
          Arca.Repo.transaction(fn ->
            TurnStorage.bind_child!(actor, step.id, gen, exec)
          end)

        n
      end

      # Proposed, not dispatched: refused.
      assert bind.(0, "exec_child_c") == 0

      {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})

      # The wrong child id and the wrong generation: refused.
      assert bind.(0, "exec_other") == 0
      assert bind.(1, "exec_child_c") == 0
      assert bind.(0, "exec_child_c") == 1

      # A cancel mark refuses a later admission.
      {:ok, superseded} = TurnStorage.supersede(actor, turn.id, %{fence: turn.fence})

      assert bind.(0, "exec_child_c") == 0

      # The next generation is a fresh child id, proposed again.
      assert {:ok, next} =
               TurnStorage.next_generation(actor, step.id, %{
                 child_execution_id: "exec_child_c2",
                 fence: superseded.fence
               })

      assert next.generation == 1 and next.dispatch_state == "proposed"
      assert is_nil(next.cancel_requested_at)
    end

    test "skipping closes the unstarted steps with a synthetic result",
         %{
           actor: actor,
           thread: thread
         } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)

      {_model, %{asks: [%{step: s1}, %{step: s2}]}} =
        respond!(actor, turn, [{"a", "files", "read"}, {"b", "files", "write"}])

      {:ok, _} = TurnStorage.dispatch_step(actor, s1.id, %{fence: turn.fence})

      assert {:ok, [skipped]} =
               TurnStorage.skip_steps(
                 actor,
                 turn.id,
                 "Skipped due to a new message",
                 %{
                   fence: turn.fence
                 }
               )

      assert skipped.id == s2.id and skipped.outcome == "skipped"

      # Its result answers its call by the call's wire id and name, which a
      # brain pairs it with.
      result = Arca.Repo.get!(Message, skipped.result_message_id)

      assert %{"tool_call_id" => "b", "name" => "files.write", "skipped" => true} =
               Arca.ThreadStorage.payload(result)

      # The dispatched step is untouched.
      assert {:ok, %{dispatch_state: "dispatched"}} = TurnStorage.step(actor, s1.id)
    end
  end

  describe "pause, resume, finish, takeover" do
    test "a launch's pause dispatches its step in the same write", %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)
      paused = launch_paused!(actor, started)

      assert {:ok, %{dispatch_state: "dispatched", started_at: %DateTime{}}} =
               TurnStorage.step(actor, paused.launch_step_id)
    end

    test "a launch's pause is refused while a model's call, a child of the root, runs: the " <>
           "launch stays proposed and the turn running",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)

      {:ok, _model} =
        TurnStorage.put_step(actor, started.id, %{
          kind: "model",
          idempotency_key: "model:1",
          child_execution_id: Prima.UUID7.execution_id(),
          dispatch_state: "dispatched",
          fence: started.fence
        })

      {:ok, launch} =
        TurnStorage.put_step(actor, started.id, %{
          kind: "launch",
          idempotency_key: "launch:1",
          fence: started.fence
        })

      assert {:error, :child_running} =
               TurnStorage.pause(actor, started.id, %{
                 fence: started.fence,
                 reason: "launch",
                 launch_step_id: launch.id
               })

      assert {:ok, %{dispatch_state: "proposed"}} = TurnStorage.step(actor, launch.id)
      assert {:ok, %{status: "running"}} = TurnStorage.get(actor, started.id)
    end

    for {kind, purpose} <- [{"tool", "chat"}, {"launch", "chat"}, {"tool", "flush"}] do
      @tag step: {kind, purpose}
      test "a turn does not complete while a #{kind} step a #{purpose} round asked is still " <>
             "proposed, whatever a harness said of its work",
           %{actor: actor, thread: thread, step: {kind, purpose}} do
        %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
        {started, _root} = start!(actor, turn)

        {:ok, asked} =
          TurnStorage.put_step(actor, started.id, %{
            kind: kind,
            purpose: purpose,
            idempotency_key: "call:1",
            fence: started.fence
          })

        completion = %{grant: :stored, verify: &Arca.Test.Actor.admits/1, fence: started.fence}

        assert {:error, :call_pending} =
                 TurnStorage.finish(actor, started.id, "completed", completion)

        {:ok, _} = TurnStorage.close_step(actor, asked.id, "skipped", %{fence: started.fence})

        assert {:ok, %{status: "completed"}} =
                 TurnStorage.finish(actor, started.id, "completed", completion)
      end
    end

    test "a turn does not complete while a model's call of it runs: its loop waits on its " <>
           "harness's work",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)

      {:ok, model} =
        TurnStorage.put_step(actor, started.id, %{
          kind: "model",
          idempotency_key: "model:1",
          child_execution_id: Prima.UUID7.execution_id(),
          dispatch_state: "dispatched",
          fence: started.fence
        })

      completion = %{grant: :stored, verify: &Arca.Test.Actor.admits/1, fence: started.fence}

      assert {:error, :call_pending} =
               TurnStorage.finish(actor, started.id, "completed", completion)

      {:ok, _} = TurnStorage.close_step(actor, model.id, "ok", %{fence: started.fence})

      assert {:ok, %{status: "completed"}} =
               TurnStorage.finish(actor, started.id, "completed", completion)
    end

    test "no model step opens while the turn is paused around a launch",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {started, _root} = start!(actor, turn)
      paused = launch_paused!(actor, started)

      assert {:error, :illegal_transition} =
               TurnStorage.put_step(actor, paused.id, %{
                 kind: "model",
                 idempotency_key: "model:1",
                 child_execution_id: Prima.UUID7.execution_id(),
                 dispatch_state: "dispatched",
                 fence: paused.fence
               })
    end

    test "pausing takes the turn, its attempt and its root out of running together, and resume brings them back",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, root} = start!(actor, turn)
      # sleep-ok: a running interval of at least 15 ms for the pause to account (active_ms >= 15)
      Process.sleep(15)

      paused = launch_paused!(actor, turn)
      assert paused.status == "paused" and paused.paused_reason == "launch"
      assert paused.active_ms >= 15

      assert %{state: "paused"} = ExecutionAttempts.get(actor, root.attempt.attempt)

      assert execution(root.execution.id).status == "paused"

      # Neither the sweeper nor retention sees a paused root.
      assert [] =
               Arca.Execution.list_stale_running(DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:ok, []} = Arca.Execution.stale_ids(0, athanor_id: actor.athanor_id)

      assert {:error, :not_running} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})

      assert {:ok, resumed} =
               TurnStorage.resume(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      assert resumed.status == "running" and is_nil(resumed.paused_reason)

      assert %{state: "running", running_since: %DateTime{}} =
               ExecutionAttempts.get(actor, root.attempt.attempt)

      assert execution(root.execution.id).status == "running"
    end

    test "finish is the one terminal write: turn, attempt, root and reservation close together, once",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, root} = start!(actor, turn)

      assert {:ok, done} =
               TurnStorage.finish(actor, turn.id, "completed", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      assert done.status == "completed"
      assert %DateTime{} = done.ended_at

      assert %{state: "completed", outcome: "ok"} =
               ExecutionAttempts.get(actor, root.attempt.attempt)

      assert execution(root.execution.id).status == "completed"

      assert %{released_at: %DateTime{}} = Arca.BudgetReservations.lookup(actor, root.budget_id)

      assert {:error, :already_finished} =
               TurnStorage.finish(actor, turn.id, "failed", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      # A turn that never started closes on its own.
      %{turn: queued} = accept_turn!(actor, thread, "@aqua later")

      assert {:ok, %{status: "cancelled"}} =
               TurnStorage.finish(actor, queued.id, "cancelled", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: queued.fence
               })

      # An uncertain end fails the root and marks the attempt uncertain.
      %{turn: t3} = accept_turn!(actor, thread, "@aqua again")
      {t3, root3} = start!(actor, t3)

      assert {:ok, %{status: "uncertain"}} =
               TurnStorage.finish(actor, t3.id, "uncertain", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 error: "restart",
                 fence: t3.fence
               })

      assert %{state: "failed", outcome: "uncertain"} =
               ExecutionAttempts.get(actor, root3.attempt.attempt)

      assert execution(root3.execution.id).status == "failed"
    end

    test "a takeover renews the fence, opens the successor and counts the recovery, up to the cap",
         %{
           actor: actor,
           thread: thread
         } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, root} = start!(actor, turn)
      lapsed = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(
          from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^root.attempt.attempt),
          set: [lease_until: lapsed]
        )

      {:ok, _} = ExecutionAttempts.lapse(root.attempt.attempt, lapsed, Arca.Test.Actor.stored())

      assert {:ok, taken} =
               TurnStorage.takeover(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      assert taken.fence != turn.fence
      assert taken.recovery_attempts == 1
      assert taken.attempt != root.attempt.attempt
      assert taken.status == "running"
      assert execution(root.execution.id).current_attempt == taken.attempt
      assert execution(root.execution.id).status == "running"

      # The old fence is refused everywhere.
      assert {:error, :superseded} = TurnStorage.pause(actor, turn.id, %{fence: turn.fence})

      # A takeover from a fence that already moved takes nothing.
      assert {:error, :superseded} =
               TurnStorage.takeover(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      {:ok, second} =
        TurnStorage.takeover(actor, turn.id, %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: taken.fence
        })

      {:ok, third} =
        TurnStorage.takeover(actor, turn.id, %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: second.fence
        })

      assert third.recovery_attempts == 3

      assert {:error, :recovery_exhausted} =
               TurnStorage.takeover(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: third.fence
               })
    end

    test "superseding renews the fence and cancel-marks every dispatched step", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)

      {_m, %{asks: [%{step: s1}, %{step: s2}]}} =
        respond!(actor, turn, [{"a", "files", "read"}, {"b", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(actor, s1.id, %{fence: turn.fence})

      assert {:ok, %{fence: fence}} = TurnStorage.supersede(actor, turn.id, %{fence: turn.fence})

      assert fence != turn.fence

      assert {:ok, %{cancel_requested_at: %DateTime{}}} = TurnStorage.step(actor, s1.id)

      assert {:ok, %{cancel_requested_at: nil}} = TurnStorage.step(actor, s2.id)

      assert {:error, :superseded} =
               TurnStorage.close_step(actor, s1.id, "ok", %{
                 fence: turn.fence
               })
    end
  end

  describe "the projection" do
    test "a turn reads its own rows uncapped, holds an undrained steer, and never a queued member's message",
         %{actor: actor, thread: thread} do
      {:ok, earlier} =
        Threads.append(actor, thread.id, %{
          author: actor.user_id,
          sent_by: "person",
          content: "earlier"
        })

      %{message: message, turn: turn} = accept_turn!(actor, thread, "@aqua read")
      {turn, _root} = start!(actor, turn)

      {_m, %{said: [text], asks: [%{message: call, step: step}]}} =
        respond!(actor, turn, [{"c", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})

      {:ok, %{result: result}} =
        TurnStorage.close_step(actor, step.id, "ok", %{
          result: %{content: "ok"},
          fence: turn.fence
        })

      # Another member queues a turn; a steer arrives from the actor.
      %{message: queued} = accept_turn!(actor, thread, "@aqua me too", author: "usr_bob")

      {:ok, %{message: steer}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "and also"},
          steer_turn_id: turn.id
        })

      assert {:ok, rows} = TurnStorage.projection(actor, turn.id)
      ids = Enum.map(rows, & &1.id)
      assert ids == [earlier.id, message.id, text.id, call.id, result.id]
      refute queued.id in ids
      refute steer.id in ids

      assert TurnStorage.steer_pending?(actor, turn.id)

      assert {:ok, [drained]} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})

      assert drained.id == steer.id

      # Taken in, it waits until a model step carries it: the next round
      # takes it in again.
      assert TurnStorage.steer_pending?(actor, turn.id)
      assert {:ok, [again]} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
      assert again.id == steer.id

      assert {:ok, rows} = TurnStorage.projection(actor, turn.id)

      assert Enum.map(rows, & &1.id) == [
               earlier.id,
               message.id,
               text.id,
               call.id,
               result.id,
               steer.id
             ]
    end

    test "a queued turn started after its predecessor finished sees the predecessor's final rows",
         %{
           actor: actor,
           thread: thread
         } do
      %{turn: a} = accept_turn!(actor, thread, "@aqua first")
      {a, _} = start!(actor, a)

      %{message: b_message, turn: b} =
        accept_turn!(actor, thread, "@aqua second", author: "usr_bob")

      %{message: c_message} = accept_turn!(actor, thread, "@aqua third", author: "usr_carol")

      {_m, %{said: [a_text], asks: [%{step: step}]}} =
        respond!(actor, a, [{"c", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(actor, step.id, %{fence: a.fence})

      {:ok, %{result: a_result}} =
        TurnStorage.close_step(actor, step.id, "ok", %{
          result: %{content: "ok"},
          fence: a.fence
        })

      {:ok, _} =
        TurnStorage.finish(actor, a.id, "completed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: a.fence
        })

      {b, _} = start!(actor, b)
      assert b.window_upto_seq == max(b_message.seq, a_result.seq)
      assert {:ok, rows} = TurnStorage.projection(actor, b.id)
      ids = Enum.map(rows, & &1.id)
      assert a_text.id in ids and a_result.id in ids and b_message.id in ids
      refute c_message.id in ids
    end

    test "draining a post accepted while queued keeps the predecessor's final rows",
         %{actor: actor, thread: thread} do
      %{turn: first} = accept_turn!(actor, thread, "first")
      {first, _} = start!(actor, first)
      %{turn: queued} = accept_turn!(actor, thread, "second")

      {:ok, %{message: post}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "and also"},
          steer_turn_id: queued.id
        })

      {_model, %{said: [answer], asks: [%{step: call}]}} =
        respond!(actor, first, [{"c", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(actor, call.id, %{fence: first.fence})

      {:ok, %{result: result}} =
        TurnStorage.close_step(actor, call.id, "ok", %{
          result: %{content: "ok"},
          fence: first.fence
        })

      {:ok, _} =
        TurnStorage.finish(actor, first.id, "completed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: first.fence
        })

      {queued, _} = start!(actor, queued)
      assert post.seq < answer.seq and answer.seq < result.seq
      assert {:ok, before} = TurnStorage.projection(actor, queued.id)
      assert answer.id in Enum.map(before, & &1.id)
      assert result.id in Enum.map(before, & &1.id)

      assert {:ok, [%{id: drained}]} =
               TurnStorage.drain_steer(actor, queued.id, %{fence: queued.fence})

      assert drained == post.id
      assert {:ok, after_drain} = TurnStorage.projection(actor, queued.id)
      assert Enum.map(after_drain, & &1.id) == Enum.map(before, & &1.id)
    end

    test "the first message of an empty thread is inside the window", %{
      actor: actor,
      thread: thread
    } do
      %{message: message, turn: turn} = accept_turn!(actor, thread, "@aqua hello")
      {turn, _} = start!(actor, turn)
      assert turn.window_upto_seq == message.seq
      assert {:ok, [%{id: id}]} = TurnStorage.projection(actor, turn.id)
      assert id == message.id
      refute TurnStorage.steer_pending?(actor, turn.id)
    end
  end

  describe "a post's place" do
    # One chat round of an API brain: the round takes in what was posted,
    # its model step opens dispatched, and it answers `text` with a read
    # call for each id, each dispatched.
    defp round!(actor, turn, text, calls \\ []) do
      {:ok, _drained} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
      model!(actor, turn, text, calls)
    end

    defp model!(actor, turn, text, calls) do
      {:ok, step} =
        TurnStorage.put_step(actor, turn.id, %{
          kind: "model",
          idempotency_key: "model:#{System.unique_integer([:positive])}",
          dispatch_state: "dispatched",
          fence: turn.fence
        })

      asks =
        for id <- calls do
          {:ask,
           %{
             kind: "tool",
             tool: "files",
             action: "read",
             recovery: "replay_safe",
             child_execution_id: "exec_child_#{turn.id}_#{id}",
             idempotency_key: "call:#{turn.id}:#{id}",
             call: %{
               kind: "tool_call",
               content: "files.read",
               payload: %{
                 "tool_call_id" => id,
                 "name" => "files.read",
                 "tool" => "files",
                 "action" => "read",
                 "arguments" => %{"path" => "a.txt"},
                 "kind" => "read",
                 "step_id" => step.id
               }
             }
           }}
        end

      {:ok, recorded} =
        TurnStorage.commit_events(actor, scope(turn), %{
          events:
            [{:text, %{text: text}}] ++
              asks ++
              [
                {:usage, usage(%{"input_tokens" => 10, "output_tokens" => 3})},
                {:stop, if(calls == [], do: "end_turn", else: "tool_call")}
              ],
          position: {:step, step.id}
        })

      for %{step: call} <- recorded.asks,
          do: {:ok, _} = TurnStorage.dispatch_step(actor, call.id, %{fence: turn.fence})

      {step, recorded}
    end

    defp result!(actor, turn, %{step: call}) do
      {:ok, %{result: result}} =
        TurnStorage.close_step(actor, call.id, "ok", %{
          result: %{content: "ok"},
          fence: turn.fence
        })

      result
    end

    defp post!(actor, thread, turn, text) do
      {:ok, %{message: post}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: text},
          steer_turn_id: turn.id
        })

      post
    end

    defp read_ids(actor, turn) do
      {:ok, rows} = TurnStorage.projection(actor, turn.id)
      Enum.map(rows, & &1.id)
    end

    defp carried_by(row), do: Arca.Repo.get!(Message, row.id).carried_by

    test "a post written while a call runs reads after the call's result and before the answer " <>
           "of the step that carried it, in every round and turn after; one written while an " <>
           "answer is written reads after that answer",
         %{actor: actor, thread: thread} do
      %{message: ask, turn: turn} = accept_turn!(actor, thread, "@aqua read it")
      {turn, _root} = start!(actor, turn)
      {first, %{said: [reply], asks: [read]}} = round!(actor, turn, "Reading.", ["c1"])
      assert carried_by(ask) == first.id

      moon = post!(actor, thread, turn, "and the moon too")
      result = result!(actor, turn, read)

      # The next round takes the post in. Should it die before its step is
      # written, the post is taken in and carried by nothing: still a steer,
      # read last, which the round after carries.
      assert {:ok, [%{id: drained}]} =
               TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})

      assert drained == moon.id
      assert TurnStorage.steer_pending?(actor, turn.id)
      assert carried_by(moon) == nil

      assert {:error, :steer_pending} =
               TurnStorage.finish(actor, turn.id, "completed", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      assert read_ids(actor, turn) == [ask.id, reply.id, read.message.id, result.id, moon.id]

      # A compaction's model step carries nothing; a post written after the
      # round read the thread waits for the step after.
      {:ok, compaction} =
        TurnStorage.put_step(actor, turn.id, %{
          kind: "model",
          purpose: "compaction",
          idempotency_key: "compaction:1",
          dispatch_state: "dispatched",
          fence: turn.fence
        })

      # A compaction's call ends before the round's own (`Aqua.Harness.Api`).
      {:ok, _} = TurnStorage.close_step(actor, compaction.id, "ok", %{fence: turn.fence})

      assert carried_by(moon) == nil
      stars = post!(actor, thread, turn, "and the stars")
      {second, %{said: [both]}} = model!(actor, turn, "Both.", [])
      assert carried_by(moon) == second.id
      assert carried_by(stars) == nil

      held = [ask.id, reply.id, read.message.id, result.id, moon.id, both.id]
      assert read_ids(actor, turn) == held

      # The stars were written while that answer was: they read after it.
      assert stars.seq < both.seq
      {third, %{said: [last]}} = round!(actor, turn, "Stars too.")
      assert carried_by(stars) == third.id
      assert read_ids(actor, turn) == held ++ [stars.id, last.id]

      {:ok, _} =
        TurnStorage.finish(actor, turn.id, "completed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: turn.fence
        })

      %{message: again, turn: next} = accept_turn!(actor, thread, "@aqua and now?")
      {next, _} = start!(actor, next)
      assert read_ids(actor, next) == held ++ [stars.id, last.id, again.id]
    end

    test "a report Aqua writes into its running turn is a steer as a person's post is: held " <>
           "until a round takes it in, kept from completing the turn, carried by that round " <>
           "alone and read where it carried it",
         %{actor: actor, thread: thread} do
      %{message: ask, turn: turn} = accept_turn!(actor, thread, "@aqua build it")
      {turn, _root} = start!(actor, turn)
      {_first, %{said: [reply], asks: [read]}} = round!(actor, turn, "Opening it.", ["c1"])

      {:ok, %{workspace: workspace}} =
        TurnStorage.open_workspace(actor, %{
          daily_id: thread.id,
          id: Prima.UUID7.generate_id("thread"),
          title: "Moon report",
          opened_from: ask.id,
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
        })

      {:ok, %{message: report}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{
            author: "aqua",
            sent_by: "aqua",
            kind: "report",
            workspace_id: workspace.id,
            content: "Done: the moon report."
          },
          steer_turn_id: turn.id
        })

      assert report.turn_id == turn.id
      result = result!(actor, turn, read)
      refute report.id in read_ids(actor, turn)
      assert TurnStorage.steer_pending?(actor, turn.id)

      assert {:error, :steer_pending} =
               TurnStorage.finish(actor, turn.id, "completed", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })

      {second, %{said: [noted]}} = round!(actor, turn, "The report is in.")
      assert carried_by(report) == second.id
      refute TurnStorage.steer_pending?(actor, turn.id)
      assert {:ok, []} = TurnStorage.drain_steer(actor, turn.id, %{fence: turn.fence})
      {_third, %{said: [last]}} = round!(actor, turn, "Nothing more.")
      assert carried_by(report) == second.id

      assert read_ids(actor, turn) -- [workspace_pointer(actor, thread)] ==
               [ask.id, reply.id, read.message.id, result.id, report.id, noted.id, last.id]

      assert {:ok, %{status: "completed"}} =
               TurnStorage.finish(actor, turn.id, "completed", %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: turn.fence
               })
    end

    # The daily thread's pointer at the workspace thread it opened.
    defp workspace_pointer(actor, thread) do
      Arca.Repo.one!(
        from(m in Message,
          where: m.athanor_id == ^actor.athanor_id and m.thread_id == ^thread.id,
          where: m.kind == "pointer",
          select: m.id
        )
      )
    end

    test "a post no round held reads after the rest of its turn, in the turns after",
         %{actor: actor, thread: thread} do
      %{message: ask, turn: turn} = accept_turn!(actor, thread, "@aqua read it")
      {turn, _root} = start!(actor, turn)
      {_first, %{said: [reply], asks: [read]}} = round!(actor, turn, "Reading.", ["c1"])
      never = post!(actor, thread, turn, "never mind")
      result = result!(actor, turn, read)

      {:ok, _} =
        TurnStorage.finish(actor, turn.id, "failed", %{
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1,
          fence: turn.fence
        })

      %{message: again, turn: next} = accept_turn!(actor, thread, "@aqua try again")
      {next, _} = start!(actor, next)
      assert never.seq < result.seq

      assert read_ids(actor, next) ==
               [ask.id, reply.id, read.message.id, result.id, never.id, again.id]
    end
  end

  describe "the uncertain stop" do
    # `n` of the steps proposed for `ids`, in order, flipped to dispatched.
    defp dispatched!(actor, turn, ids, n) do
      {_model, %{asks: calls}} = respond!(actor, turn, Enum.map(ids, &{&1, "http", "get"}))

      calls
      |> Enum.with_index()
      |> Enum.map(fn {%{step: step}, i} ->
        if i < n do
          {:ok, step} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})

          step
        else
          step
        end
      end)
    end

    test "a post written while the call ran is no steer while the turn is stopped on it, " <>
           "though no step carried it: the sender's line after the stop is",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)
      [c1] = dispatched!(actor, turn, ["c1"], 1)

      {:ok, %{message: early}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "and also"},
          steer_turn_id: turn.id
        })

      assert TurnStorage.steer_pending?(actor, turn.id)

      {:ok, _} =
        TurnStorage.pause_uncertain(actor, turn.id, %{
          fence: turn.fence,
          step_id: c1.id,
          generation: 0,
          reason: "the worker died"
        })

      refute TurnStorage.steer_pending?(actor, turn.id)
      assert Arca.Repo.get!(Message, early.id).carried_by == nil

      {:ok, _} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go on"},
          steer_turn_id: turn.id
        })

      assert TurnStorage.steer_pending?(actor, turn.id)

      {:ok, resumed} =
        TurnStorage.resume(actor, turn.id, %{
          fence: turn.fence,
          grant: :stored,
          verify: &Arca.Test.Actor.admits/1
        })

      assert {:ok, posts} = TurnStorage.drain_steer(actor, turn.id, %{fence: resumed.fence})
      assert Enum.map(posts, & &1.content) == ["and also", "go on"]

      {:ok, carrier} =
        TurnStorage.put_step(actor, turn.id, %{
          kind: "model",
          purpose: "chat",
          dispatch_state: "dispatched",
          idempotency_key: "review:after-ack",
          fence: resumed.fence
        })

      assert Arca.Repo.get!(Message, early.id).carried_by == carrier.id
      refute TurnStorage.steer_pending?(actor, turn.id)
    end

    test "a mark takes the turn's fence and the step's generation", %{
      actor: actor,
      thread: thread
    } do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, _root} = start!(actor, turn)
      [step] = dispatched!(actor, turn, ["c1"], 1)

      assert {:error, :fence_required} =
               TurnStorage.mark_step_uncertain(actor, step.id, "x", %{
                 generation: 0
               })

      assert {:error, :superseded} =
               TurnStorage.mark_step_uncertain(actor, step.id, "x", %{
                 fence: turn.fence - 1,
                 generation: 0
               })

      assert {:error, :not_dispatched} =
               TurnStorage.mark_step_uncertain(actor, step.id, "x", %{
                 fence: turn.fence,
                 generation: 7
               })

      assert {:ok, %{dispatch_state: "uncertain", outcome: "uncertain", error: "x"}} =
               TurnStorage.mark_step_uncertain(actor, step.id, "x", %{
                 fence: turn.fence,
                 generation: 0
               })

      assert TurnStorage.restricted?(actor, turn.id)
    end

    test "the stop is one transaction: the mark, the cancel-marks, the skips, the covering row, the boundary",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, root} = start!(actor, turn)
      [c1, c2, c3] = dispatched!(actor, turn, ["c1", "c2", "c3"], 2)
      assert c1.dispatch_state == "dispatched" and c2.dispatch_state == "dispatched"
      assert c3.dispatch_state == "proposed"

      assert {:error, :fence_required} =
               TurnStorage.pause_uncertain(actor, turn.id, %{
                 step_id: c1.id,
                 generation: 0
               })

      assert {:ok, %{turn: paused, aborted: row}} =
               TurnStorage.pause_uncertain(actor, turn.id, %{
                 fence: turn.fence,
                 step_id: c1.id,
                 generation: 0,
                 reason: "the worker died"
               })

      assert paused.status == "paused" and paused.paused_reason == "uncertain"
      assert paused.window_upto_seq == row.seq
      assert row.kind == "turn_aborted"

      assert %{"covers" => covers} = Threads.payload(row)
      assert Enum.sort(Enum.map(covers, & &1["step_id"])) == Enum.sort([c1.id, c2.id])
      assert Enum.all?(covers, &(&1["generation"] == 0))

      {:ok, steps} = TurnStorage.steps(actor, turn.id)

      assert %{dispatch_state: "uncertain", error: "the worker died"} =
               Enum.find(steps, &(&1.id == c1.id))

      assert %{dispatch_state: "dispatched", cancel_requested_at: %DateTime{}} =
               Enum.find(steps, &(&1.id == c2.id))

      assert %{dispatch_state: "closed", outcome: "skipped"} = Enum.find(steps, &(&1.id == c3.id))

      # The root and its attempt left running with the turn.
      assert execution(root.execution.id).status == "paused"

      assert %{state: "paused"} = ExecutionAttempts.get(actor, root.attempt.attempt)

      assert TurnStorage.unacknowledged_episode?(actor, turn.id)
      assert TurnStorage.restricted?(actor, turn.id)

      # A sibling settled after the boundary is covered already: a mark, no second row.
      assert {:ok, _} =
               TurnStorage.mark_step_uncertain(actor, c2.id, "cancelled", %{
                 fence: paused.fence,
                 generation: 0
               })

      rows = Threads.messages(actor, thread.id)
      assert [_] = Enum.filter(rows, &(&1.kind == "turn_aborted"))

      # The sender's next line past the boundary acknowledges it.
      {:ok, _} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "go on"},
          steer_turn_id: turn.id
        })

      refute TurnStorage.unacknowledged_episode?(actor, turn.id)
      assert TurnStorage.restricted?(actor, turn.id)
      assert TurnStorage.steer_pending?(actor, turn.id)
    end

    test "a running turn a dead runner left with an uncovered uncertainty is set down paused, its attempt retired",
         %{actor: actor, thread: thread} do
      %{turn: turn} = accept_turn!(actor, thread, "@aqua go")
      {turn, root} = start!(actor, turn)
      [c1, c2] = dispatched!(actor, turn, ["c1", "c2"], 2)

      # A mark alone, as a sibling's, with no covering row.
      {:ok, _} =
        TurnStorage.mark_step_uncertain(actor, c1.id, "lost", %{
          fence: turn.fence,
          generation: 0
        })

      assert TurnStorage.unacknowledged_episode?(actor, turn.id)

      # The sweeper lapsed the root attempt in the meantime.
      {1, _} =
        Arca.Repo.update_all(
          from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^root.attempt.attempt),
          set: [state: "lapsed", outcome: "uncertain", running_since: nil]
        )

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^root.execution.id),
          set: [status: "failed"]
        )

      assert {:ok, paused} =
               TurnStorage.pause_recovered(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 content: "restarted",
                 fence: turn.fence
               })

      assert paused.status == "paused" and paused.paused_reason == "uncertain"
      assert paused.attempt != root.attempt.attempt and paused.fence != turn.fence
      assert paused.recovery_attempts == turn.recovery_attempts

      assert %{state: "paused"} = ExecutionAttempts.get(actor, paused.attempt)

      assert execution(root.execution.id).status == "paused"

      {:ok, steps} = TurnStorage.steps(actor, turn.id)
      # A dispatched replay-safe read has nothing to judge: it closes, uncovered.
      assert %{dispatch_state: "closed", outcome: "error"} = Enum.find(steps, &(&1.id == c2.id))

      [row] =
        Enum.filter(
          Threads.messages(actor, thread.id),
          &(&1.kind == "turn_aborted")
        )

      assert paused.window_upto_seq == row.seq

      covered =
        row |> Threads.payload() |> Map.fetch!("covers") |> Enum.map(& &1["step_id"])

      assert covered == [c1.id]

      # Resumable: the successor attempt is the paused owner.
      assert {:ok, %{status: "running"}} =
               TurnStorage.resume(actor, turn.id, %{
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1,
                 fence: paused.fence
               })
    end
  end
end
