# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryTableTest do
  @moduledoc """
  A turn paused around a launch, found at recovery: a launch step already
  dispatched is an unknown outcome, so the turn is stopped uncertain on
  it and waits for its sender, the launch never dispatched again; a
  launch step never dispatched leaves the turn to continue, and a turn
  another process holds is left to it.
  """

  use ExUnit.Case, async: false

  alias Aqua.Runner.{RecoveryPolicy, RecoveryTable}
  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.TestContext.athanor!()
    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  defp started!(ctx) do
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_rtable_#{System.unique_integer([:positive])}",
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

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        recovery_limit: RecoveryPolicy.max_attempts()
      })

    turn
  end

  # The turn as `Aqua.Loop`'s launch leaves it when the server stops: the
  # launch step proposed by a model response, dispatched when `dispatch?`,
  # and the turn paused around it with its root let go.
  defp paused_on_launch!(ctx, turn, dispatch?) do
    {:ok, model} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: proposed}]}} =
      Tape.record_response(ctx, turn, model, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "l1",
            name: "execution.run",
            tool: "execution",
            action: "run",
            arguments: %{"reference" => "formula:local.nowhere:1.0.0", "input" => %{}},
            kind: "execute",
            step_kind: "launch"
          }
        ]
      })

    launch =
      if dispatch? do
        {:ok, dispatched} = Tape.mark_dispatched(ctx, turn, proposed)
        dispatched
      else
        proposed
      end

    {:ok, %{status: "paused", paused_reason: "launch"}} =
      Arca.TurnStorage.pause(Sanctum.Context.actor(ctx), turn.id, %{
        fence: turn.fence,
        reason: "launch",
        launch_step_id: launch.id
      })

    launch
  end

  defp aborted(ctx, turn),
    do:
      Enum.filter(
        Threads.messages(Sanctum.Context.actor(ctx), turn.thread_id),
        &(&1.kind == "turn_aborted")
      )

  test "a launch already dispatched is paused uncertain at recovery, never replayed", %{ctx: ctx} do
    turn = started!(ctx)
    launch = paused_on_launch!(ctx, turn, true)
    assert launch.dispatch_state == "dispatched"
    turn_id = turn.id
    assert aborted(ctx, turn) == []

    assert {:ok,
            [
              {:wait,
               %{id: ^turn_id, status: "paused", paused_reason: "uncertain", launch_step_id: nil}}
            ]} = RecoveryTable.plan(ctx, turn.thread_id)

    # The launch is closed uncertain in its own generation, not dispatched
    # again, and the turn carries one row saying it stopped on it.
    assert {:ok,
            %{
              dispatch_state: "uncertain",
              outcome: "uncertain",
              error: "the server stopped while the application was launched",
              generation: generation
            }} = Tape.step(ctx, launch.id)

    assert generation == launch.generation
    {:ok, steps} = Tape.steps(ctx, turn)
    assert [%{id: only}] = Enum.filter(steps, &(&1.kind == "launch"))
    assert only == launch.id
    assert [_covering] = aborted(ctx, turn)

    # Set down, not taken over: no recovery spent, the fence unmoved.
    assert {:ok, %{status: "paused", paused_reason: "uncertain", recovery_attempts: 0} = paused} =
             Tape.turn(ctx, turn_id)

    assert paused.fence == turn.fence

    # Planned again, it still waits on its sender, and nothing is settled twice.
    assert {:ok, [{:wait, %{id: ^turn_id, paused_reason: "uncertain"}}]} =
             RecoveryTable.plan(ctx, turn.thread_id)

    assert [_covering] = aborted(ctx, turn)

    assert {:ok, %{dispatch_state: "uncertain", generation: ^generation}} =
             Tape.step(ctx, launch.id)
  end

  test "a launch never dispatched leaves the turn to continue", %{ctx: ctx} do
    turn = started!(ctx)
    launch = paused_on_launch!(ctx, turn, false)
    turn_id = turn.id

    assert {:ok, [{:continue, %{id: ^turn_id, paused_reason: "launch"}}]} =
             RecoveryTable.plan(ctx, turn.thread_id)

    assert {:ok, %{dispatch_state: "proposed"}} = Tape.step(ctx, launch.id)
    assert aborted(ctx, turn) == []
  end

  test "a dispatched launch whose turn another process holds is left to it", %{ctx: ctx} do
    turn = started!(ctx)
    launch = paused_on_launch!(ctx, turn, true)
    turn_id = turn.id
    me = self()

    {:ok, _} = Registry.register(Aqua.RunnerRegistry, {:turn, turn_id}, nil)

    assert {:ok, [{:held, %{id: ^turn_id}, ^me}]} = RecoveryTable.plan(ctx, turn.thread_id)
    assert {:ok, %{dispatch_state: "dispatched"}} = Tape.step(ctx, launch.id)
    assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, turn_id)
    assert aborted(ctx, turn) == []
  end
end
