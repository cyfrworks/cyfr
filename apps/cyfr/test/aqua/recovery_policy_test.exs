# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryPolicyTest do
  @moduledoc """
  The recovery cap is the assistant's policy and the turn row enforces
  it: a turn stores the policy's limit when it starts, each takeover or
  recovery spends one of it under the turn's lock, a limit a caller names
  later never widens it, and the count is the turn's own. Of a recovery
  and a takeover racing from one fence, one lands.
  """

  use ExUnit.Case, async: false

  alias Aqua.Runner.RecoveryPolicy
  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
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
          id: "exec_policy_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id
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

  test "the cap is the assistant's policy, and the store keeps none of its own" do
    assert RecoveryPolicy.max_attempts() == 3

    Code.ensure_loaded!(Arca.TurnStorage)
    refute function_exported?(Arca.TurnStorage, :recovery_cap, 0)
    Code.ensure_loaded!(Tape)
    refute function_exported?(Tape, :recovery_cap, 0)
  end

  test "a started turn stores the policy's limit, and a fourth takeover is refused", %{ctx: ctx} do
    turn = started!(ctx)
    assert turn.recovery_limit == RecoveryPolicy.max_attempts()

    last =
      Enum.reduce(1..RecoveryPolicy.max_attempts(), turn, fn n, turn ->
        assert {:ok, taken} = Tape.bump_recovery(ctx, turn)
        assert taken.recovery_attempts == n
        taken
      end)

    assert {:error, :recovery_exhausted} = Tape.bump_recovery(ctx, last)

    # A caller naming a wider limit changes nothing: the row's is the one.
    assert {:error, :recovery_exhausted} = Tape.recover(ctx, last, 100)

    assert {:ok, %{recovery_attempts: 3, recovery_limit: 3}} = Tape.turn(ctx, turn.id)
  end

  test "the count is each turn's own", %{ctx: ctx} do
    spent = started!(ctx)
    fresh = started!(ctx)

    Enum.reduce(1..RecoveryPolicy.max_attempts(), spent, fn _, turn ->
      {:ok, taken} = Tape.bump_recovery(ctx, turn)
      taken
    end)

    assert {:ok, %{recovery_attempts: 1}} = Tape.bump_recovery(ctx, fresh)
  end

  test "of a recovery and a takeover from one fence, one lands", %{ctx: ctx} do
    turn = started!(ctx)

    results =
      [
        fn -> Tape.recover(ctx, turn, RecoveryPolicy.max_attempts()) end,
        fn -> Tape.bump_recovery(ctx, turn) end
      ]
      |> Enum.map(&Task.async/1)
      |> Enum.map(&Task.await(&1, 25_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [{:error, :superseded}] = Enum.reject(results, &match?({:ok, _}, &1))
    assert {:ok, %{recovery_attempts: 1}} = Tape.turn(ctx, turn.id)
  end
end
