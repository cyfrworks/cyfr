# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ExecutionState do
  @moduledoc """
  The execution's vocabulary: the statuses an execution row carries, the
  states an attempt at it is in and the outcomes an attempt closes with,
  each split into those that still own work and those that are over, and
  the moves a status write may make between them.

  Every set is a list of the strings the rows store, so a query can bind
  it and a guard can test membership. Persistence, its transitions and
  the baseline's CHECKs read these sets; they are defined nowhere else. A
  turn's statuses are `Prima.TurnState`'s, never these.

  A write states the narrowest move its operation makes (a pause moves
  only a running row); `transition?/3` is the bound every such write stays
  within. An execution reopens only by a recovery: a successor takes up a
  `failed` row whose current attempt lapsed (`Arca.ExecutionAttempts`),
  and a `completed` or `cancelled` row never moves. An attempt never
  reopens: a successor is a new attempt.
  """

  @statuses ~w(running paused completed failed cancelled)
  @open ~w(running paused)
  @terminal ~w(completed failed cancelled)

  @attempt_states ~w(running paused completed failed cancelled lapsed)
  @attempt_open ~w(running paused)
  @attempt_terminal ~w(completed failed cancelled lapsed)
  @outcomes ~w(ok error result_lost cancelled uncertain)

  # The statuses each status may be written over, keyed by the status
  # written. A recovery's successor puts a lapsed `failed` row back to
  # `running`, or straight to `paused` when it resumes held.
  @execution_from %{
    "running" => ~w(running paused failed),
    "paused" => ~w(running paused failed),
    "completed" => @open,
    "failed" => @open,
    "cancelled" => @open
  }

  # An attempt is inserted `running`; a pause and a resume move it
  # between the open two, and every end, a lapse among them, leaves an
  # open one.
  @attempt_from %{
    "running" => ~w(paused),
    "paused" => ~w(running),
    "completed" => @attempt_open,
    "failed" => @attempt_open,
    "cancelled" => @attempt_open,
    "lapsed" => @attempt_open
  }

  @typedoc "What a status write moves: an execution row or an attempt row."
  @type domain :: :execution | :attempt

  @doc "Every status an execution can carry."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses of an execution that still owns work."
  @spec open_statuses() :: [String.t()]
  def open_statuses, do: @open

  @doc "The statuses of an execution that is over."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @doc "Every state an attempt can be in."
  @spec attempt_states() :: [String.t()]
  def attempt_states, do: @attempt_states

  @doc "The states of an attempt that still owns work."
  @spec open_attempt_states() :: [String.t()]
  def open_attempt_states, do: @attempt_open

  @doc "The states of an attempt that no longer owns work."
  @spec terminal_attempt_states() :: [String.t()]
  def terminal_attempt_states, do: @attempt_terminal

  @doc "Every outcome an attempt can close with; an open attempt has none."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Whether `status` is one an execution that still owns work carries."
  @spec open?(term()) :: boolean()
  def open?(status), do: status in @open

  @doc "Whether `status` is one an execution that is over carries."
  @spec terminal?(term()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc """
  The states a row of `domain` may hold for a status write to move it to
  `to`: `[]` for a status nothing moves to, or one outside the domain.
  """
  @spec from(domain(), term()) :: [String.t()]
  def from(:execution, to), do: Map.get(@execution_from, to, [])
  def from(:attempt, to), do: Map.get(@attempt_from, to, [])

  @doc "Whether a status write may move a row of `domain` from `from` to `to`."
  @spec transition?(domain(), term(), term()) :: boolean()
  def transition?(domain, from, to) when domain in [:execution, :attempt],
    do: from in from(domain, to)
end
