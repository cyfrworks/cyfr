# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnTapeStorageTest do
  @moduledoc """
  The durable turn: acceptance is atomic with the work it opens; a step
  is proposed before its effect and closed with its result; approvals
  consume a proposal; pause, resume, finish and takeover move the turn,
  its attempt and its root execution together; the projection reads
  behind a consumption boundary that a queued turn never crosses.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ConversationStorage, as: Conversations
  alias Arca.ExecutionAttempts
  alias Arca.Schemas.Message
  alias Arca.TurnStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    {:ok, conv} = Conversations.create(ctx)
    {:ok, ctx: ctx, conv: conv}
  end

  # A turn root: a `kind: "turn"` execution with its reservation.
  defp root!(ctx, turn_id) do
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn_id
        },
        reservation: %{budget_id: budget_id, cap: 4}
      )

    %{execution: execution, attempt: attempt, budget_id: budget_id}
  end

  defp accept_turn!(ctx, conv, text, opts \\ []) do
    {:ok, %{message: message, turn: turn}} =
      TurnStorage.accept_message(ctx, conv.id, %{
        message: %{
          author: Keyword.get(opts, :author, ctx.user_id),
          content: text,
          client_id: Keyword.get(opts, :client_id)
        },
        turn: %{
          orchestrator: "aqua",
          requested_by: Keyword.get(opts, :author, ctx.user_id),
          model: Keyword.get(opts, :model),
          options: %{"room" => nil}
        }
      })

    %{message: message, turn: turn}
  end

  defp start!(ctx, turn) do
    root = root!(ctx, turn.id)

    {:ok, started} =
      TurnStorage.start(ctx, turn.id, %{
        root_execution_id: root.execution.id,
        attempt: root.attempt.attempt,
        budget_id: root.budget_id,
        profile_id: "prof_x",
        consent_id: "consent_x",
        agent_revision_digest: "sha256:rev",
        agent_capability_digest: "sha256:cap",
        fence: turn.fence
      })

    {started, root}
  end

  defp execution(id), do: Arca.Repo.get!(Arca.Execution, id)

  defp respond!(ctx, turn, calls) do
    {:ok, step} = TurnStorage.put_step(ctx, turn.id, %{kind: "model", idempotency_key: "model:1"})

    {:ok, recorded} =
      TurnStorage.record_response(ctx, turn.id, step.id, %{
        text: "On it.",
        usage: %{"input_tokens" => 10, "output_tokens" => 3},
        stop_reason: "tool_call",
        tool_calls:
          Enum.map(calls, fn {id, tool, action} ->
            %{
              tool_call_id: id,
              name: "#{tool}.#{action}",
              tool: tool,
              action: action,
              arguments: %{"path" => "a.txt"},
              provider_data: %{"thought_signature" => "sig-" <> id},
              kind: "read",
              recovery: "replay_safe",
              idempotency_key: "call:#{turn.id}:1:#{id}",
              proposal_digest: "sha256:" <> id,
              child_execution_id: "exec_child_" <> id
            }
          end)
      })

    {step, recorded}
  end

  describe "acceptance" do
    test "room content is a row alone; an addressed message opens its turn atomically", %{
      ctx: ctx,
      conv: conv
    } do
      assert {:ok, %{message: post, turn: nil}} =
               TurnStorage.accept_message(ctx, conv.id, %{
                 message: %{author: ctx.user_id, content: "just saying"}
               })

      assert post.seq == 1 and is_nil(post.turn_id)

      %{message: message, turn: turn} = accept_turn!(ctx, conv, "@aqua do it", client_id: "c-1")
      assert turn.status == "accepted"
      assert turn.message_id == message.id
      assert turn.fence != ""
      assert turn.runner_id == Cyfr.Boot.id()
      assert {:ok, %{turn_seq: 1, orchestrator: "aqua"}} = Conversations.get(ctx, conv.id)

      # The same client id is one acceptance: the retry finds it.
      assert {:error, :duplicate_client_id} =
               TurnStorage.accept_message(ctx, conv.id, %{
                 message: %{author: ctx.user_id, content: "@aqua do it", client_id: "c-1"},
                 turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
               })

      assert {:ok, %{message: %{id: mid}, turn: %{id: tid}}} =
               TurnStorage.accepted(ctx, conv.id, "c-1")

      assert mid == message.id and tid == turn.id
      assert {:ok, [%{id: ^tid}]} = TurnStorage.open_turns(ctx, conv.id)
    end

    test "a steer attaches to the live turn without opening another", %{ctx: ctx, conv: conv} do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, _root} = start!(ctx, turn)

      assert {:ok, %{message: steer, turn: %{id: tid}}} =
               TurnStorage.accept_message(ctx, conv.id, %{
                 message: %{author: ctx.user_id, content: "also this"},
                 steer_turn_id: turn.id
               })

      assert tid == turn.id and steer.turn_id == turn.id
      assert {:ok, [_]} = TurnStorage.open_turns(ctx, conv.id)
      assert TurnStorage.steer_pending?(ctx, turn.id)
    end
  end

  describe "start" do
    test "an accepted turn starts once, with its pins and the boundary at its own message", %{
      ctx: ctx,
      conv: conv
    } do
      {:ok, _} = Conversations.append(ctx, conv.id, %{author: ctx.user_id, content: "earlier"})
      %{message: message, turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {started, root} = start!(ctx, turn)

      assert started.status == "running"
      assert started.root_execution_id == root.execution.id
      assert started.attempt == root.attempt.attempt
      assert started.budget_id == root.budget_id
      assert started.consent_id == "consent_x"
      assert started.window_upto_seq == message.seq

      assert {:error, :not_accepted} =
               TurnStorage.start(ctx, turn.id, %{root_execution_id: root.execution.id})

      # A superseded fence writes nothing.
      assert {:error, :superseded} = TurnStorage.pause(ctx, turn.id, %{fence: "fnc_old"})
    end
  end

  describe "steps" do
    test "a response is committed before any call runs, each call dispatches once and closes with its result",
         %{ctx: ctx, conv: conv} do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua read a.txt")
      {turn, root} = start!(ctx, turn)

      {model_step, %{text: text, calls: [%{message: call_row, step: call_step}]}} =
        respond!(ctx, turn, [{"call_1", "files", "read"}])

      assert text.kind == "text" and text.turn_id == turn.id
      assert call_row.kind == "tool_call"

      assert %{"provider_data" => %{"thought_signature" => "sig-call_1"}} =
               Conversations.payload(call_row)

      assert call_step.dispatch_state == "proposed"
      assert call_step.child_execution_id == "exec_child_call_1"
      assert call_step.recovery == "replay_safe"

      assert {:ok, %{dispatch_state: "closed", outcome: "ok", usage: usage}} =
               TurnStorage.step(ctx, model_step.id)

      assert usage =~ "input_tokens"

      assert {:ok, %{dispatch_state: "dispatched", started_at: %DateTime{}}} =
               TurnStorage.dispatch_step(ctx, call_step.id, %{fence: turn.fence})

      assert {:error, :not_proposed} = TurnStorage.dispatch_step(ctx, call_step.id)

      assert {:ok, %{step: closed, result: result}} =
               TurnStorage.close_step(ctx, call_step.id, "ok", %{
                 result: %{content: "line 1", payload: %{"tool_call_id" => "call_1"}},
                 execution_id: "exec_child_call_1",
                 fence: turn.fence
               })

      assert closed.outcome == "ok" and closed.result_message_id == result.id
      assert result.kind == "tool_result" and result.author == Message.system_author()
      assert {:error, :not_open} = TurnStorage.close_step(ctx, call_step.id, "ok")

      assert {:ok, events} = Arca.ExecutionEvents.since(ctx.athanor_id, root.execution.id, 0)

      assert Enum.map(events, & &1.type) ==
               ["execution.started", "turn.started", "model.completed", "step.closed"]
    end

    test "the step barrier binds only a dispatched, current, uncancelled generation", %{
      ctx: ctx,
      conv: conv
    } do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, _root} = start!(ctx, turn)
      {_model, %{calls: [%{step: step}]}} = respond!(ctx, turn, [{"c", "files", "read"}])

      bind = fn gen, exec ->
        {:ok, n} =
          Arca.Repo.transaction(fn ->
            TurnStorage.bind_child!(ctx.athanor_id, step.id, gen, exec)
          end)

        n
      end

      # Proposed, not dispatched: refused.
      assert bind.(0, "exec_child_c") == 0
      {:ok, _} = TurnStorage.dispatch_step(ctx, step.id)
      # The wrong child id and the wrong generation: refused.
      assert bind.(0, "exec_other") == 0
      assert bind.(1, "exec_child_c") == 0
      assert bind.(0, "exec_child_c") == 1

      # A cancel mark refuses a later admission.
      {:ok, _} = TurnStorage.supersede(ctx, turn.id)
      assert bind.(0, "exec_child_c") == 0

      # The next generation is a fresh child id, proposed again.
      assert {:ok, next} =
               TurnStorage.next_generation(ctx, step.id, %{child_execution_id: "exec_child_c2"})

      assert next.generation == 1 and next.dispatch_state == "proposed"
      assert is_nil(next.cancel_requested_at)
    end

    test "skipping closes the unstarted steps with a synthetic result and invalidates their cards",
         %{
           ctx: ctx,
           conv: conv
         } do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, _root} = start!(ctx, turn)

      {_model, %{calls: [%{step: s1}, %{step: s2}]}} =
        respond!(ctx, turn, [{"a", "files", "read"}, {"b", "files", "write"}])

      {:ok, %{approval: approval, card: card}} =
        TurnStorage.open_approval(ctx, s2.id, %{
          proposal_digest: "sha256:b",
          card: %{content: "Write a.txt?", payload: %{"intent" => %{}}}
        })

      {:ok, _} = TurnStorage.dispatch_step(ctx, s1.id)

      assert {:ok, [skipped]} =
               TurnStorage.skip_steps(ctx, turn.id, "Skipped due to a new message")

      assert skipped.id == s2.id and skipped.outcome == "skipped"
      assert {:ok, %{status: "invalidated"}} = TurnStorage.approval(ctx, approval.id)
      assert %{status: "invalidated"} = Arca.Repo.get!(Message, card.id)
      # The dispatched step is untouched.
      assert {:ok, %{dispatch_state: "dispatched"}} = TurnStorage.step(ctx, s1.id)
    end
  end

  describe "approvals" do
    test "a decision consumes the card once: approved returns the step to proposed, declined closes it denied",
         %{ctx: ctx, conv: conv} do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, _root} = start!(ctx, turn)

      {_model, %{calls: [%{step: s1}, %{step: s2}]}} =
        respond!(ctx, turn, [{"a", "files", "write"}, {"b", "files", "delete"}])

      {:ok, %{approval: a1, card: card1}} =
        TurnStorage.open_approval(ctx, s1.id, %{
          proposal_digest: "sha256:a",
          card: %{content: "a?"}
        })

      assert card1.approval_id == a1.id and card1.status == "pending"
      assert {:ok, %{step_id: sid}} = TurnStorage.approval_by_message(ctx, card1.id)
      assert sid == s1.id
      assert {:ok, [%{id: aid}]} = TurnStorage.pending_approvals(ctx, turn.id)
      assert aid == a1.id

      assert {:ok, %{approval: %{status: "approved", decided_by: who}, step: step, card: card}} =
               TurnStorage.resolve_approval(ctx, a1.id, "approved", %{
                 decided_by: ctx.user_id,
                 scope: "once",
                 resolution_kind: "continue",
                 resolution: %{"scope" => "once"}
               })

      assert who == ctx.user_id and step.dispatch_state == "proposed" and
               card.status == "approved"

      assert {:error, {:already_resolved, %{status: "approved"}}} =
               TurnStorage.resolve_approval(ctx, a1.id, "declined", %{decided_by: ctx.user_id})

      {:ok, %{approval: a2}} =
        TurnStorage.open_approval(ctx, s2.id, %{
          proposal_digest: "sha256:b",
          card: %{content: "b?"}
        })

      assert {:ok, %{step: denied, approval: %{status: "declined"}}} =
               TurnStorage.resolve_approval(ctx, a2.id, "declined", %{
                 decided_by: ctx.user_id,
                 resolution_kind: "denied",
                 reason: "no",
                 denied_result: %{content: "did not run: declined", payload: %{"denied" => true}}
               })

      assert denied.outcome == "denied" and denied.dispatch_state == "closed"

      assert %{kind: "tool_result", content: "did not run: declined"} =
               Arca.Repo.get!(Message, denied.result_message_id)

      assert {:ok, []} = TurnStorage.pending_approvals(ctx, turn.id)
    end
  end

  describe "pause, resume, finish, takeover" do
    test "pausing takes the turn, its attempt and its root out of running together, and resume brings them back",
         %{ctx: ctx, conv: conv} do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, root} = start!(ctx, turn)
      Process.sleep(15)

      assert {:ok, paused} =
               TurnStorage.pause(ctx, turn.id, %{reason: "approval", fence: turn.fence})

      assert paused.status == "paused" and paused.paused_reason == "approval"
      assert paused.active_ms >= 15
      assert %{state: "paused"} = ExecutionAttempts.get(ctx.athanor_id, root.attempt.attempt)
      assert execution(root.execution.id).status == "paused"

      # Neither the sweeper nor retention sees a paused root.
      assert [] =
               Arca.Execution.list_stale_running(DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:ok, []} = Arca.Execution.stale_ids(0, athanor_id: ctx.athanor_id)
      assert {:error, :not_running} = TurnStorage.pause(ctx, turn.id)

      assert {:ok, resumed} = TurnStorage.resume(ctx, turn.id, %{fence: turn.fence})
      assert resumed.status == "running" and is_nil(resumed.paused_reason)

      assert %{state: "running", running_since: %DateTime{}} =
               ExecutionAttempts.get(ctx.athanor_id, root.attempt.attempt)

      assert execution(root.execution.id).status == "running"
    end

    test "finish is the one terminal write: turn, attempt, root and reservation close together, once",
         %{ctx: ctx, conv: conv} do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, root} = start!(ctx, turn)

      assert {:ok, done} = TurnStorage.finish(ctx, turn.id, "completed", %{fence: turn.fence})
      assert done.status == "completed"
      assert %DateTime{} = done.ended_at

      assert %{state: "completed", outcome: "ok"} =
               ExecutionAttempts.get(ctx.athanor_id, root.attempt.attempt)

      assert execution(root.execution.id).status == "completed"

      assert %{released_at: %DateTime{}} =
               Arca.BudgetReservations.lookup(ctx.athanor_id, root.budget_id)

      assert {:error, :already_finished} = TurnStorage.finish(ctx, turn.id, "failed")

      # A turn that never started closes on its own.
      %{turn: queued} = accept_turn!(ctx, conv, "@aqua later")
      assert {:ok, %{status: "cancelled"}} = TurnStorage.finish(ctx, queued.id, "cancelled")

      # An uncertain end fails the root and marks the attempt uncertain.
      %{turn: t3} = accept_turn!(ctx, conv, "@aqua again")
      {t3, root3} = start!(ctx, t3)

      assert {:ok, %{status: "uncertain"}} =
               TurnStorage.finish(ctx, t3.id, "uncertain", %{error: "restart"})

      assert %{state: "failed", outcome: "uncertain"} =
               ExecutionAttempts.get(ctx.athanor_id, root3.attempt.attempt)

      assert execution(root3.execution.id).status == "failed"
    end

    test "a takeover renews the fence, opens the successor and counts the recovery, up to the cap",
         %{
           ctx: ctx,
           conv: conv
         } do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, root} = start!(ctx, turn)
      lapsed = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        Arca.Repo.update_all(
          from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^root.attempt.attempt),
          set: [lease_until: lapsed]
        )

      {:ok, _} = ExecutionAttempts.lapse(root.attempt.attempt, lapsed)

      assert {:ok, taken} = TurnStorage.takeover(ctx, turn.id)
      assert taken.fence != turn.fence
      assert taken.recovery_attempts == 1
      assert taken.attempt != root.attempt.attempt
      assert taken.status == "running"
      assert execution(root.execution.id).current_attempt == taken.attempt
      assert execution(root.execution.id).status == "running"

      # The old fence is refused everywhere.
      assert {:error, :superseded} = TurnStorage.pause(ctx, turn.id, %{fence: turn.fence})

      {:ok, _} = TurnStorage.takeover(ctx, turn.id)
      {:ok, third} = TurnStorage.takeover(ctx, turn.id)
      assert third.recovery_attempts == 3
      assert {:error, :recovery_exhausted} = TurnStorage.takeover(ctx, turn.id)
    end

    test "superseding renews the fence and cancel-marks every dispatched step", %{
      ctx: ctx,
      conv: conv
    } do
      %{turn: turn} = accept_turn!(ctx, conv, "@aqua go")
      {turn, _root} = start!(ctx, turn)

      {_m, %{calls: [%{step: s1}, %{step: s2}]}} =
        respond!(ctx, turn, [{"a", "files", "read"}, {"b", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(ctx, s1.id)

      assert {:ok, %{fence: fence}} = TurnStorage.supersede(ctx, turn.id)
      assert fence != turn.fence
      assert {:ok, %{cancel_requested_at: %DateTime{}}} = TurnStorage.step(ctx, s1.id)
      assert {:ok, %{cancel_requested_at: nil}} = TurnStorage.step(ctx, s2.id)

      assert {:error, :superseded} =
               TurnStorage.close_step(ctx, s1.id, "ok", %{fence: turn.fence})
    end
  end

  describe "the projection" do
    test "a turn reads its own rows uncapped, holds an undrained steer, and never a queued member's message",
         %{ctx: ctx, conv: conv} do
      {:ok, earlier} =
        Conversations.append(ctx, conv.id, %{author: ctx.user_id, content: "earlier"})

      %{message: message, turn: turn} = accept_turn!(ctx, conv, "@aqua read")
      {turn, _root} = start!(ctx, turn)

      {_m, %{text: text, calls: [%{message: call, step: step}]}} =
        respond!(ctx, turn, [{"c", "files", "read"}])

      {:ok, _} = TurnStorage.dispatch_step(ctx, step.id)

      {:ok, %{result: result}} =
        TurnStorage.close_step(ctx, step.id, "ok", %{result: %{content: "ok"}})

      # Another member queues a turn; a steer arrives from the actor.
      %{message: queued} = accept_turn!(ctx, conv, "@aqua me too", author: "usr_bob")

      {:ok, %{message: steer}} =
        TurnStorage.accept_message(ctx, conv.id, %{
          message: %{author: ctx.user_id, content: "and also"},
          steer_turn_id: turn.id
        })

      assert {:ok, rows} = TurnStorage.projection(ctx, turn.id)
      ids = Enum.map(rows, & &1.id)
      assert ids == [earlier.id, message.id, text.id, call.id, result.id]
      refute queued.id in ids
      refute steer.id in ids

      assert TurnStorage.steer_pending?(ctx, turn.id)
      assert {:ok, [drained]} = TurnStorage.drain_steer(ctx, turn.id)
      assert drained.id == steer.id
      refute TurnStorage.steer_pending?(ctx, turn.id)
      assert {:ok, []} = TurnStorage.drain_steer(ctx, turn.id)

      assert {:ok, rows} = TurnStorage.projection(ctx, turn.id)

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
           ctx: ctx,
           conv: conv
         } do
      %{turn: a} = accept_turn!(ctx, conv, "@aqua first")
      {a, _} = start!(ctx, a)
      %{message: b_message, turn: b} = accept_turn!(ctx, conv, "@aqua second", author: "usr_bob")
      %{message: c_message} = accept_turn!(ctx, conv, "@aqua third", author: "usr_carol")

      {_m, %{text: a_text, calls: [%{step: step}]}} = respond!(ctx, a, [{"c", "files", "read"}])
      {:ok, _} = TurnStorage.dispatch_step(ctx, step.id)

      {:ok, %{result: a_result}} =
        TurnStorage.close_step(ctx, step.id, "ok", %{result: %{content: "ok"}})

      {:ok, _} = TurnStorage.finish(ctx, a.id, "completed")

      {b, _} = start!(ctx, b)
      assert b.window_upto_seq == max(b_message.seq, a_result.seq)
      assert {:ok, rows} = TurnStorage.projection(ctx, b.id)
      ids = Enum.map(rows, & &1.id)
      assert a_text.id in ids and a_result.id in ids and b_message.id in ids
      refute c_message.id in ids
    end

    test "the first message of an empty conversation is inside the window", %{
      ctx: ctx,
      conv: conv
    } do
      %{message: message, turn: turn} = accept_turn!(ctx, conv, "@aqua hello")
      {turn, _} = start!(ctx, turn)
      assert turn.window_upto_seq == message.seq
      assert {:ok, [%{id: id}]} = TurnStorage.projection(ctx, turn.id)
      assert id == message.id
      refute TurnStorage.steer_pending?(ctx, turn.id)
    end

    test "a clone reads its own rows only, and the parent sees the clone's rows not at all", %{
      ctx: ctx,
      conv: conv
    } do
      %{turn: parent} = accept_turn!(ctx, conv, "@aqua build")
      {parent, root} = start!(ctx, parent)

      assert {:ok, %{turn: clone, step: step, task: task}} =
               TurnStorage.open_clone_turn(ctx, parent.id, %{
                 role: "builder",
                 task: "make it",
                 fence: parent.fence
               })

      assert clone.parent_turn_id == parent.id
      assert clone.root_execution_id == root.execution.id
      assert clone.attempt == root.attempt.attempt
      assert step.kind == "clone" and step.dispatch_state == "dispatched"
      assert task.turn_id == clone.id

      assert {:ok, [%{id: tid}]} = TurnStorage.projection(ctx, clone.id)
      assert tid == task.id
      assert {:ok, rows} = TurnStorage.projection(ctx, parent.id)
      refute task.id in Enum.map(rows, & &1.id)

      assert {:error, :clone_depth} =
               TurnStorage.open_clone_turn(ctx, clone.id, %{role: "web", task: "x"})

      assert {:ok, %{status: "completed"}} =
               TurnStorage.close_clone_turn(ctx, clone.id, "completed")

      assert {:error, :not_a_clone} = TurnStorage.close_clone_turn(ctx, parent.id, "completed")
    end
  end
end
