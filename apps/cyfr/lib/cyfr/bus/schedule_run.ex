# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ScheduleRun do
  @moduledoc """
  A schedule fired, or could not run or ran and failed, on
  `Cyfr.Bus.schedule_runs/1`. Distinct from `Cyfr.Bus.Schedules`, which
  says the schedule rows changed. `reason` is bounded.
  """

  alias Cyfr.Bus.Payload

  @kinds [:fired, :failed]
  @fields [:schedule_id, :occurrence_id, :execution_id, :reference, :reason]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :fired | :failed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          schedule_id: String.t() | nil,
          occurrence_id: String.t() | nil,
          execution_id: String.t() | nil,
          reference: String.t() | nil,
          reason: atom() | String.t() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `reason` is projected through `Cyfr.Bus.bounded_reason/1`.
  """
  @spec new(Cyfr.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Cyfr.Actor{} = actor, kind, fields \\ %{}) do
    fields = Map.new(fields)

    fields =
      Enum.reduce([:reason], fields, fn key, acc ->
        if Map.has_key?(acc, key),
          do: Map.update!(acc, key, &Cyfr.Bus.bounded_reason/1),
          else: acc
      end)

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
