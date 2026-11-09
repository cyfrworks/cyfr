# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ScheduleRun do
  @moduledoc """
  A schedule fired, or could not run or ran and failed, on
  `Cyfr.Bus.schedule_runs/1`. Only a row of kind `schedule` fires here; a
  feed's fire is a `Cyfr.Bus.FeedRun`. Distinct from `Cyfr.Bus.Schedules`,
  which says the schedule rows changed. `scheduled_for` is the
  occurrence's due time, nil with `occurrence_id` for a failure before any
  occurrence was claimed. `reason` is a refusal: its class and the cause
  it reads as (`causes/0`), never its sentence.
  """

  alias Cyfr.Bus.Payload

  @kinds [:fired, :failed]
  @fields [:schedule_id, :occurrence_id, :execution_id, :scheduled_for, :reason]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind, :revision, :at | @fields]

  @type kind :: :fired | :failed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          revision: non_neg_integer(),
          at: DateTime.t(),
          schedule_id: String.t() | nil,
          occurrence_id: String.t() | nil,
          execution_id: String.t() | nil,
          scheduled_for: DateTime.t() | nil,
          reason: %{class: Prima.Refusal.class(), cause: atom()} | nil
        }

  # What each cause says of a schedule's run.
  @causes [
    failed: "The schedule's run failed.",
    cancelled: "The schedule's run was cancelled.",
    timed_out: "The schedule's run ran out of time.",
    refused: "The schedule's run was refused.",
    needs_setup: "The schedule needs a setup or a grant first.",
    waits_for_you: "The schedule's run waits for your confirmation.",
    rate_limited: "The schedule's run reached a limit.",
    unavailable: "Something the schedule's run needs is unavailable.",
    bad_input: "The schedule's input could not be used.",
    not_found: "Something the schedule names was not found.",
    uncertain: "The schedule's run's outcome is uncertain."
  ]

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Every cause a reason reads as, each with its readable sentence, in one
  order: the finite set a canvas lists and reads.
  """
  @spec causes() :: [{atom(), String.t()}]
  def causes, do: @causes

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `reason` is a refusal's class and cause (`%{class, cause}`).
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    fields = fields |> Map.new() |> Payload.caused([:reason])

    Payload.build(__MODULE__, [:revision, :at | @fields], Payload.stamped(fields), %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
