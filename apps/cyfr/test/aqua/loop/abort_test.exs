# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.AbortTest do
  @moduledoc """
  Aborting a turn from outside its process: the fence moves first, a
  catalog handler still running for a dispatched call is stopped, and each
  dispatched step settles by `Arca.Schemas.TurnStep.unresolved/1` — an
  ordinary call is recorded `uncertain`, since a cancel does not prove the
  effect never happened.
  """

  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage

  setup do
    Cyfr.Test.Sandbox.setup!()
    ctx = Sanctum.TestContext.local()
    {:ok, thread} = Threads.create(ctx)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {:ok, ctx: ctx, turn: turn}
  end

  test "an in-process handler still running is stopped, and its call is uncertain", %{
    ctx: ctx,
    turn: turn
  } do
    {:ok, model} =
      TurnStorage.put_step(ctx, turn.id, %{kind: "model", fence: turn.fence})

    {:ok, %{calls: [%{step: call}]}} =
      TurnStorage.record_response(ctx, turn.id, model.id, %{
        fence: turn.fence,
        tool_calls: [%{tool_call_id: "c1", name: "notes.keep", tool: "notes", action: "keep"}]
      })

    {:ok, call} = TurnStorage.dispatch_step(ctx, call.id, %{fence: turn.fence})

    handler = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(handler)
    :ok = Emissary.MCP.RunningTasks.register_handle({turn.id, call.id, call.generation}, handler)

    assert {:ok, aborted} = Aqua.Loop.abort(ctx, turn, "stopped")
    assert aborted.fence != turn.fence

    assert_receive {:DOWN, ^ref, :process, ^handler, :cancelled}, 1_000
    assert {:ok, %{dispatch_state: "uncertain"}} = TurnStorage.step(ctx, call.id)

    # The loop that held the old fence writes nothing more.
    assert {:error, :superseded} =
             TurnStorage.close_step(ctx, call.id, "ok", %{fence: turn.fence})
  end

  test "a model request closes as an error, and a flush's call closes with its outcome unknown",
       %{
         ctx: ctx,
         turn: turn
       } do
    {:ok, flush} =
      TurnStorage.put_step(ctx, turn.id, %{kind: "model", purpose: "flush", fence: turn.fence})

    {:ok, %{calls: [%{step: note}]}} =
      TurnStorage.record_response(ctx, turn.id, flush.id, %{
        fence: turn.fence,
        tool_calls: [%{tool_call_id: "n1", name: "notes", tool: "notes", action: "keep"}]
      })

    {:ok, _} = TurnStorage.dispatch_step(ctx, note.id, %{fence: turn.fence})

    {:ok, model} =
      TurnStorage.put_step(ctx, turn.id, %{
        kind: "model",
        dispatch_state: "dispatched",
        fence: turn.fence
      })

    assert {:ok, _aborted} = Aqua.Loop.abort(ctx, turn, "stopped")

    assert {:ok, %{dispatch_state: "closed", outcome: "uncertain"}} =
             TurnStorage.step(ctx, note.id)

    assert {:ok, %{dispatch_state: "closed", outcome: "error"}} = TurnStorage.step(ctx, model.id)
    refute TurnStorage.restricted?(ctx, turn.id)
  end
end
