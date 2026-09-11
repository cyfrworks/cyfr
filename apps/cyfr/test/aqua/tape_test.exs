# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TapeTest do
  @moduledoc """
  The tape commits before it speaks: a row reaches the conversation's
  topic only once its transaction landed; a fence that moved refuses the
  write; a sender's replay answers the same acceptance and a changed
  send is refused; a guest-planed context writes unchanged.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ConversationStorage, as: Conversations

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    {:ok, conv} = Conversations.create(ctx)
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, conv.id))
    {:ok, ctx: ctx, conv: conv}
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
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4}
      )

    {execution, attempt}
  end

  defp started!(ctx, conv, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {execution, attempt} = root!(ctx, turn)

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x"
      })

    turn
  end

  test "acceptance is one transaction and one broadcast, and a replay answers the same identity",
       %{
         ctx: ctx,
         conv: conv
       } do
    send_attrs = %{
      message: %{author: ctx.user_id, content: "@aqua go", client_id: "c-1"},
      turn: %{
        orchestrator: "aqua",
        requested_by: ctx.user_id,
        model: nil,
        options: %{"room" => nil}
      }
    }

    assert {:ok, %{message: message, turn: turn, replayed: false}} =
             Tape.accept(ctx, conv.id, send_attrs)

    assert_receive {:conversation, conv_id, {:message, %{id: mid}}}
    assert conv_id == conv.id and mid == message.id

    assert {:ok, %{message: %{id: ^mid}, turn: %{id: tid}, replayed: true}} =
             Tape.accept(ctx, conv.id, send_attrs)

    assert tid == turn.id
    refute_receive {:conversation, _, {:message, _}}, 100

    changed = put_in(send_attrs, [:message, :content], "@aqua something else")
    assert {:error, :client_id_reused} = Tape.accept(ctx, conv.id, changed)

    other_actor = put_in(send_attrs, [:message, :author], "usr_bob")
    assert {:error, :client_id_reused} = Tape.accept(ctx, conv.id, other_actor)
  end

  test "rows are broadcast only after they committed, and a moved fence refuses", %{
    ctx: ctx,
    conv: conv
  } do
    turn = started!(ctx, conv, "@aqua read")
    assert_receive {:conversation, _, {:message, _}}
    guest = Sanctum.Context.enter_guest(ctx)

    {:ok, step} = Tape.record_model_intent(guest, turn, %{idempotency_key: "model:1"})

    assert {:ok, %{text: text, calls: [%{message: call, step: call_step}]}} =
             Tape.record_response(guest, turn, step, %{
               text: "Reading.",
               usage: %{"input_tokens" => 1},
               stop_reason: "tool_call",
               tool_calls: [
                 %{
                   tool_call_id: "c1",
                   name: "files.read",
                   tool: "files",
                   action: "read",
                   arguments: %{},
                   kind: "read",
                   idempotency_key: "call:1:c1",
                   child_execution_id: "exec_c1"
                 }
               ]
             })

    assert_receive {:conversation, _, {:message, %{id: text_id}}}
    assert text_id == text.id
    assert_receive {:conversation, _, {:message, %{id: call_id}}}
    assert call_id == call.id

    assert {:ok, [%{id: ^text_id}, %{id: ^call_id}]} =
             (fn ->
                {:ok, rows} = Tape.projection(guest, turn)
                {:ok, Enum.drop(rows, 1)}
              end).()

    assert {:ok, _} = Tape.mark_dispatched(guest, turn, call_step)

    assert {:ok, %{result: result}} =
             Tape.close_step(guest, turn, call_step, "ok", %{result: %{content: "line"}})

    assert_receive {:conversation, _, {:message, %{id: result_id}}}
    assert result_id == result.id

    # The fence moves: the old turn value writes nothing more.
    {:ok, superseded} = Tape.supersede(ctx, turn)
    assert superseded.fence != turn.fence
    assert {:error, :superseded} = Tape.record_model_intent(guest, turn, %{})
    refute_receive {:conversation, _, _}, 50

    assert {:ok, finished} = Tape.finish(ctx, superseded, "cancelled", %{error: "stopped"})
    assert finished.status == "cancelled"
    assert_receive {:conversation, _, {:turn_finished}}
  end

  test "a card is announced to the estate, and its decision too", %{ctx: ctx, conv: conv} do
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))
    turn = started!(ctx, conv, "@aqua write")
    {:ok, step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: call_step}]}} =
      Tape.record_response(ctx, turn, step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "w",
            name: "files.write",
            tool: "files",
            action: "write",
            arguments: %{},
            kind: "write"
          }
        ]
      })

    assert {:ok, %{approval: approval, card: card}} =
             Tape.open_approval(ctx, turn, call_step, %{
               proposal_digest: "sha256:w",
               card: %{content: "Write?"}
             })

    assert_receive {:notify, _, :approval_pending, %{approval_id: aid}}
    assert aid == approval.id
    assert card.approval_id == approval.id

    assert {:ok, %{step: %{dispatch_state: "proposed"}}} =
             Tape.resolve_approval(ctx, turn, approval.id, "approved", %{
               decided_by: ctx.user_id,
               resolution_kind: "continue"
             })

    assert_receive {:notify, _, :approval_resolved, %{decision: "approved"}}
    assert {:ok, []} = Tape.pending_approvals(ctx, turn)
    assert {:ok, %{status: "approved"}} = Tape.approval(ctx, approval.id)
  end
end
