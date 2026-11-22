# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TapeTest do
  @moduledoc """
  The tape commits before it speaks: a row reaches the thread's
  topic only once its transaction landed; a fence that moved refuses the
  write; a sender's replay answers the same acceptance and a changed
  send is refused; a guest-planed context writes unchanged.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local(:prism)
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  defp root!(ctx, turn) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_tape_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {execution, attempt}
  end

  defp started!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {execution, attempt} = root!(ctx, turn)

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    turn
  end

  test "acceptance is one transaction and one broadcast, and a replay answers the same identity",
       %{
         ctx: ctx,
         thread: thread
       } do
    send_attrs = %{
      message: %{author: ctx.user_id, sent_by: "person", content: "@aqua go", client_id: "c-1"},
      turn: %{
        agent: "aqua",
        requested_by: ctx.user_id,
        model: nil,
        options: %{"room" => nil}
      }
    }

    assert {:ok, %{message: message, turn: turn, replayed: false}} =
             Tape.accept(ctx, thread.id, send_attrs)

    assert_receive %ThreadEvent{thread_id: thread_id, kind: :message, data: %{id: mid}}
    assert thread_id == thread.id and mid == message.id

    assert {:ok, %{message: %{id: ^mid}, turn: %{id: tid}, replayed: true}} =
             Tape.accept(ctx, thread.id, send_attrs)

    assert tid == turn.id
    refute_receive %ThreadEvent{kind: :message, data: _}, 100

    changed = put_in(send_attrs, [:message, :content], "@aqua something else")
    assert {:error, :client_id_reused} = Tape.accept(ctx, thread.id, changed)

    other_actor = put_in(send_attrs, [:message, :author], "usr_bob")
    assert {:error, :client_id_reused} = Tape.accept(ctx, thread.id, other_actor)
  end

  test "a message id already taken is the same send by its client id, and another's otherwise",
       %{ctx: ctx, thread: thread} do
    id = Prima.UUID7.generate_id("msg")

    attrs = %{
      message: %{
        author: ctx.user_id,
        sent_by: "person",
        content: "@aqua go",
        id: id,
        client_id: "c-id"
      },
      turn: %{agent: "aqua", requested_by: ctx.user_id}
    }

    assert {:ok, %{message: %{id: ^id}, turn: turn, replayed: false}} =
             Tape.accept(ctx, thread.id, attrs)

    assert {:ok, %{message: %{id: ^id}, turn: ^turn, replayed: true}} =
             Tape.accept(ctx, thread.id, attrs)

    # The same id under another client id, or under none, is another send.
    other = put_in(attrs, [:message, :client_id], "c-other")
    assert {:error, :message_id_reused} = Tape.accept(ctx, thread.id, other)

    bare = update_in(attrs, [:message], &Map.delete(&1, :client_id))
    assert {:error, :message_id_reused} = Tape.accept(ctx, thread.id, bare)

    assert [_] = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
  end

  test "a turn's usage reads one way on either harness: its counted steps added up by model, " <>
         "partial when one result was not counted, unknown while none was",
       %{ctx: ctx, thread: thread} do
    turn = started!(ctx, thread, "@aqua count")
    guest = Sanctum.Context.enter_guest(ctx)
    scope = %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}}

    respond = fn usage ->
      {:ok, step} =
        Tape.record_model_intent(guest, turn, %{
          idempotency_key: "model:#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Tape.commit_events(guest, scope, %{events: [{:usage, usage}], position: {:step, step.id}})
    end

    counts = fn input, output ->
      %{
        "models" => [
          %{"model" => "m", "counts" => %{"input_tokens" => input, "output_tokens" => output}}
        ],
        "accounting" => "complete"
      }
    end

    assert Tape.usage(guest, thread.id) ==
             %{input: 0, output: 0, models: [], accounting: :unavailable}

    respond.(counts.(10, 4))

    assert Tape.usage(guest, thread.id) ==
             %{input: 10, output: 4, models: ["m"], accounting: :complete}

    respond.(counts.(5, 1))
    respond.(%{"models" => [], "accounting" => "unavailable"})

    assert Tape.usage(guest, thread.id) ==
             %{input: 15, output: 5, models: ["m"], accounting: :partial}
  end

  test "rows are broadcast only after they committed, and a moved fence refuses", %{
    ctx: ctx,
    thread: thread
  } do
    turn = started!(ctx, thread, "@aqua read")
    assert_receive %ThreadEvent{kind: :message, data: _}
    guest = Sanctum.Context.enter_guest(ctx)

    {:ok, step} = Tape.record_model_intent(guest, turn, %{idempotency_key: "model:1"})

    assert {:ok, %{said: [text], asks: [%{message: call, step: call_step}]}} =
             Tape.commit_events(
               guest,
               %{
                 thread: turn.thread_id,
                 agent: turn.agent,
                 turn: %{id: turn.id, fence: turn.fence}
               },
               %{
                 events: [
                   {:text, %{text: "Reading."}},
                   {:ask,
                    %{
                      kind: "tool",
                      tool: "files",
                      action: "read",
                      child_execution_id: "exec_c1",
                      idempotency_key: "call:1:c1",
                      call: %{
                        kind: "tool_call",
                        content: "files.read",
                        payload: %{
                          "tool_call_id" => "c1",
                          "name" => "files.read",
                          "tool" => "files",
                          "action" => "read",
                          "arguments" => %{},
                          "kind" => "read",
                          "step_id" => step.id
                        }
                      }
                    }},
                   {:usage,
                    %{
                      "models" => [%{"model" => "m", "counts" => %{"input_tokens" => 1}}],
                      "accounting" => "complete"
                    }},
                   {:stop, "tool_call"}
                 ],
                 position: {:step, step.id}
               }
             )

    assert_receive %ThreadEvent{kind: :message, data: %{id: text_id}}
    assert text_id == text.id
    assert_receive %ThreadEvent{kind: :message, data: %{id: call_id}}
    assert call_id == call.id

    assert {:ok, [%{id: ^text_id}, %{id: ^call_id}]} =
             (fn ->
                {:ok, rows} = Tape.projection(guest, turn)
                {:ok, Enum.drop(rows, 1)}
              end).()

    assert {:ok, _} = Tape.mark_dispatched(guest, turn, call_step)

    assert {:ok, %{result: result}} =
             Tape.close_step(guest, turn, call_step, "ok", %{result: %{content: "line"}})

    assert_receive %ThreadEvent{kind: :message, data: %{id: result_id}}
    assert result_id == result.id

    # The fence moves: the old turn value writes nothing more.
    {:ok, superseded} = Tape.supersede(ctx, turn)
    assert superseded.fence != turn.fence
    assert {:error, :superseded} = Tape.record_model_intent(guest, turn, %{})
    refute_receive %ThreadEvent{}, 50

    # The rows a turn owns but no step produced change what the next request
    # reads, so a superseded runner must not be able to add one either.
    assert {:error, :superseded} =
             Tape.append_compaction(guest, turn, %{
               summary: "from a runner that no longer owns this turn",
               first_kept_seq: 1,
               summarized_through_seq: 0
             })

    assert {:error, :superseded} = Tape.append_aborted(guest, turn, "stopped")
    refute_receive %ThreadEvent{}, 50

    assert {:ok, finished} = Tape.finish(ctx, superseded, "cancelled", %{error: "stopped"})
    assert finished.status == "cancelled"
    assert_receive %ThreadEvent{kind: :turn_finished}
  end

  test "a daily thread deleted takes its crew members' threads, leaves the other days, and frees its date",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)
    {:ok, other_day} = Arca.Test.Days.thread(actor)
    {:ok, child} = Threads.crew_thread(actor, thread.id, "planner")

    {:ok, _} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "bye"}
      })

    assert {:ok, %{cancelled: []}} = Tape.delete_thread(ctx, thread.id)

    for gone <- [thread.id, child.id], do: assert({:error, :not_found} = Tape.thread(ctx, gone))
    assert {:ok, %{id: kept}} = Tape.thread(ctx, other_day.id)
    assert kept == other_day.id

    # The date is free again: the day is made anew, holding nothing.
    assert {:ok, again} = Threads.daily(actor, thread.day)
    refute again.id == thread.id
    assert Threads.messages(actor, again.id) == []
  end
end
