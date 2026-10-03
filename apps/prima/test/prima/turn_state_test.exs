# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TurnStateTest do
  @moduledoc """
  The durable turn's vocabulary is one definition: the status sets
  partition every status into open and terminal, the step, outcome,
  decision, pause, scope and recovery sets are exact, a decision writes
  one resolution, and a terminal status maps to exactly one attempt end
  and one execution status.
  """
  use ExUnit.Case, async: true

  alias Prima.TurnState

  test "every status is open or terminal, never both" do
    assert Enum.sort(TurnState.open_statuses() ++ TurnState.terminal_statuses()) ==
             Enum.sort(TurnState.statuses())

    assert MapSet.disjoint?(
             MapSet.new(TurnState.open_statuses()),
             MapSet.new(TurnState.terminal_statuses())
           )

    for status <- TurnState.statuses() do
      assert TurnState.open?(status) != TurnState.terminal?(status)
    end

    refute TurnState.open?("unknown")
    refute TurnState.terminal?(nil)
  end

  test "the sets are exact" do
    assert TurnState.statuses() ==
             ["accepted", "running", "paused", "completed", "failed", "cancelled", "uncertain"]

    assert TurnState.open_statuses() == ["accepted", "running", "paused"]
    assert TurnState.terminal_statuses() == ["completed", "failed", "cancelled", "uncertain"]
    assert TurnState.step_kinds() == ["model", "tool", "ui", "approval", "clone", "launch"]

    assert TurnState.outcomes() ==
             ["ok", "error", "denied", "skipped", "cancelled", "uncertain"]

    assert TurnState.decisions() == ["approved", "declined", "expired", "error"]
    assert TurnState.pause_reasons() == ["approval", "launch"]
    assert TurnState.opening_states() == ["proposed", "dispatched"]
    assert TurnState.recoveries() == ["replay_safe"]
    assert TurnState.approval_scopes() == ["once", "thread", "always", "never"]
  end

  test "a decision writes one resolution and never turns a step into a launch" do
    assert TurnState.resolution_kind("approved", "launch") == "launch"

    for kind <- TurnState.step_kinds() -- ["launch"] do
      assert TurnState.resolution_kind("approved", kind) == "continue"
    end

    for kind <- TurnState.step_kinds() do
      assert TurnState.resolution_kind("declined", kind) == "denied"
      assert TurnState.resolution_kind("expired", kind) == "expired"
      assert TurnState.resolution_kind("error", kind) == "denied"
    end

    assert_raise FunctionClauseError, fn -> TurnState.resolution_kind("maybe", "tool") end
  end

  test "a replay-safe recovery is the one Prima.TurnStep replays" do
    for recovery <- TurnState.recoveries() do
      assert Prima.TurnStep.unresolved(%{kind: "tool", recovery: recovery}) == :replay
    end
  end

  test "a terminal status writes one attempt end and one execution status" do
    assert TurnState.attempt_end("completed") == {"completed", "ok"}
    assert TurnState.attempt_end("failed") == {"failed", "error"}
    assert TurnState.attempt_end("cancelled") == {"cancelled", "cancelled"}
    assert TurnState.attempt_end("uncertain") == {"failed", "uncertain"}

    assert TurnState.status_of("completed") == "completed"
    assert TurnState.status_of("failed") == "failed"
    assert TurnState.status_of("cancelled") == "cancelled"
    assert TurnState.status_of("uncertain") == "failed"

    for status <- TurnState.terminal_statuses() do
      {_state, outcome} = TurnState.attempt_end(status)
      assert outcome in TurnState.outcomes()
    end
  end

  test "an open status has no terminal mapping" do
    for status <- TurnState.open_statuses() do
      assert_raise FunctionClauseError, fn -> TurnState.attempt_end(status) end
      assert_raise FunctionClauseError, fn -> TurnState.status_of(status) end
    end
  end
end
