# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TurnState do
  @moduledoc """
  The durable turn's vocabulary: the statuses a turn carries, which of
  them still own work and which are over, the kinds a turn step has, the
  states a step is recorded in, the recovery a call may be reviewed
  with, the outcomes a step closes with, the decisions an approval takes
  and the resolution each writes, the reasons a runner pauses a turn
  for, and what a turn's terminal status writes on its root attempt and
  root execution.

  Every set is a list of the strings the rows store, so a query can bind
  it and a guard can test membership. Persistence and its transitions
  read these sets; they are defined nowhere else.
  """

  @statuses ["accepted", "running", "paused", "completed", "failed", "cancelled", "uncertain"]
  @open ["accepted", "running", "paused"]
  @terminal ["completed", "failed", "cancelled", "uncertain"]
  @step_kinds ["model", "tool", "ui", "approval", "clone", "launch"]
  @outcomes ["ok", "error", "denied", "skipped", "cancelled", "uncertain"]
  @decisions ["approved", "declined", "expired", "error"]
  @pause_reasons ["approval", "launch"]
  @opening_states ["proposed", "dispatched"]
  @recoveries ["replay_safe"]
  @approval_scopes ["once", "thread", "always", "never"]

  @typedoc "A turn's status as its row stores it."
  @type status :: String.t()

  @typedoc "A turn's terminal status: one of `terminal_statuses/0`."
  @type terminal :: String.t()

  @doc "Every status a turn can carry."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "The statuses of a turn that still owns work."
  @spec open_statuses() :: [status()]
  def open_statuses, do: @open

  @doc "The statuses of a turn that is over."
  @spec terminal_statuses() :: [terminal()]
  def terminal_statuses, do: @terminal

  @doc "Every kind a turn step can have."
  @spec step_kinds() :: [String.t()]
  def step_kinds, do: @step_kinds

  @doc "Every outcome a turn step can close with."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Every decision an approval can take."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc """
  The reasons a runner pauses its running turn for: a card waiting on a
  person, or a launch it handed to a person. A suspension and an unknown
  outcome pause a turn too, but only their own transitions write them.
  """
  @spec pause_reasons() :: [String.t()]
  def pause_reasons, do: @pause_reasons

  @doc "The states a step may be recorded in: proposed, or already dispatched."
  @spec opening_states() :: [String.t()]
  def opening_states, do: @opening_states

  @doc """
  The recoveries a call's step may carry besides none: `replay_safe`, a
  call reviewed safe to dispatch again (`Prima.TurnStep.unresolved/1`).
  """
  @spec recoveries() :: [String.t()]
  def recoveries, do: @recoveries

  @doc "The scopes a person answers an approval with."
  @spec approval_scopes() :: [String.t()]
  def approval_scopes, do: @approval_scopes

  @doc """
  The resolution a decision writes on an approval of a step of
  `step_kind`: an approved launch stays a launch, any other approved
  step continues, a decline or an error denies, and an expiry expires.
  A decision never changes the step's kind.
  """
  @spec resolution_kind(String.t(), String.t()) :: String.t()
  def resolution_kind("approved", "launch"), do: "launch"
  def resolution_kind("approved", _step_kind), do: "continue"
  def resolution_kind("declined", _step_kind), do: "denied"
  def resolution_kind("expired", _step_kind), do: "expired"
  def resolution_kind("error", _step_kind), do: "denied"

  @doc "Whether `status` is one a turn that still owns work carries."
  @spec open?(term()) :: boolean()
  def open?(status), do: status in @open

  @doc "Whether `status` is one a turn that is over carries."
  @spec terminal?(term()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc """
  The state and outcome a turn's terminal status writes on its root
  attempt: an `uncertain` turn's attempt failed, with an `uncertain`
  outcome.
  """
  @spec attempt_end(terminal()) :: {String.t(), String.t()}
  def attempt_end("completed"), do: {"completed", "ok"}
  def attempt_end("failed"), do: {"failed", "error"}
  def attempt_end("cancelled"), do: {"cancelled", "cancelled"}
  def attempt_end("uncertain"), do: {"failed", "uncertain"}

  @doc """
  The status a turn's terminal status writes on its root execution: an
  execution knows no `uncertain`, so an `uncertain` turn's root failed.
  """
  @spec status_of(terminal()) :: String.t()
  def status_of("uncertain"), do: "failed"
  def status_of(status) when status in @terminal, do: status
end
