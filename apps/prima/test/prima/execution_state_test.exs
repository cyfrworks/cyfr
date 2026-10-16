# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ExecutionStateTest do
  @moduledoc """
  The execution's vocabulary is one definition: the execution statuses
  and the attempt states each partition into open and terminal, the
  outcomes are exact, and the from-tables admit exactly the moves the
  stores make — a recovery may put a failed execution back to running or
  paused, nothing reopens a completed or cancelled one, and nothing
  reopens an attempt.
  """
  use ExUnit.Case, async: true

  alias Prima.ExecutionState

  @unknown [nil, "", "bogus", "accepted", "lapsed_ok", :running]

  test "the execution statuses are exact and split into open and terminal" do
    assert ExecutionState.statuses() == ~w(running paused completed failed cancelled)
    assert ExecutionState.open_statuses() == ~w(running paused)
    assert ExecutionState.terminal_statuses() == ~w(completed failed cancelled)

    assert Enum.sort(ExecutionState.open_statuses() ++ ExecutionState.terminal_statuses()) ==
             Enum.sort(ExecutionState.statuses())

    for status <- ExecutionState.statuses() do
      assert ExecutionState.open?(status) != ExecutionState.terminal?(status)
    end

    for status <- @unknown do
      refute ExecutionState.open?(status)
      refute ExecutionState.terminal?(status)
    end
  end

  test "the attempt states and outcomes are exact, and every state is open or terminal" do
    assert ExecutionState.attempt_states() ==
             ~w(running paused completed failed cancelled lapsed)

    assert ExecutionState.open_attempt_states() == ~w(running paused)
    assert ExecutionState.terminal_attempt_states() == ~w(completed failed cancelled lapsed)
    assert ExecutionState.outcomes() == ~w(ok error result_lost cancelled uncertain)

    assert Enum.sort(
             ExecutionState.open_attempt_states() ++ ExecutionState.terminal_attempt_states()
           ) == Enum.sort(ExecutionState.attempt_states())

    assert MapSet.disjoint?(
             MapSet.new(ExecutionState.open_attempt_states()),
             MapSet.new(ExecutionState.terminal_attempt_states())
           )
  end

  # Every (from, to) pair over the domain's states and a few strangers;
  # exactly the listed moves are admitted.
  @execution_moves MapSet.new([
                     {"running", "running"},
                     {"paused", "running"},
                     {"failed", "running"},
                     {"running", "paused"},
                     {"paused", "paused"},
                     {"failed", "paused"},
                     {"running", "completed"},
                     {"paused", "completed"},
                     {"running", "failed"},
                     {"paused", "failed"},
                     {"running", "cancelled"},
                     {"paused", "cancelled"}
                   ])

  @attempt_moves MapSet.new([
                   {"paused", "running"},
                   {"running", "paused"},
                   {"running", "completed"},
                   {"paused", "completed"},
                   {"running", "failed"},
                   {"paused", "failed"},
                   {"running", "cancelled"},
                   {"paused", "cancelled"},
                   {"running", "lapsed"},
                   {"paused", "lapsed"}
                 ])

  test "an execution moves only as its from-table admits" do
    states = ExecutionState.statuses() ++ @unknown

    for from <- states, to <- states do
      assert ExecutionState.transition?(:execution, from, to) ==
               MapSet.member?(@execution_moves, {from, to}),
             "execution #{inspect(from)} -> #{inspect(to)}"
    end
  end

  test "an attempt moves only as its from-table admits, and never leaves a terminal state" do
    states = ExecutionState.attempt_states() ++ @unknown

    for from <- states, to <- states do
      assert ExecutionState.transition?(:attempt, from, to) ==
               MapSet.member?(@attempt_moves, {from, to}),
             "attempt #{inspect(from)} -> #{inspect(to)}"
    end

    for from <- ExecutionState.terminal_attempt_states(), to <- ExecutionState.attempt_states() do
      refute ExecutionState.transition?(:attempt, from, to)
    end
  end

  test "a completed or cancelled execution never moves, and every end leaves an open one" do
    for from <- ~w(completed cancelled), to <- ExecutionState.statuses() do
      refute ExecutionState.transition?(:execution, from, to)
    end

    for to <- ExecutionState.terminal_statuses() do
      assert ExecutionState.from(:execution, to) == ExecutionState.open_statuses()
    end

    for to <- ExecutionState.terminal_attempt_states() do
      assert ExecutionState.from(:attempt, to) == ExecutionState.open_attempt_states()
    end

    assert ExecutionState.from(:execution, "bogus") == []
    assert ExecutionState.from(:attempt, "bogus") == []
  end

  test "an unknown domain is not a vocabulary" do
    assert_raise FunctionClauseError, fn ->
      ExecutionState.transition?(:turn, "running", "paused")
    end

    assert_raise FunctionClauseError, fn -> ExecutionState.from(:turn, "running") end
  end
end
