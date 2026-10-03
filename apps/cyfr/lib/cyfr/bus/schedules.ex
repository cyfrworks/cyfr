# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Schedules do
  @moduledoc """
  A schedule's occurrence started or its run ended, on
  `Cyfr.Bus.schedules/1` — the change the scheduler produces. Creating,
  editing, pausing or removing a schedule row announces nothing here.
  Distinct from `Cyfr.Bus.ScheduleRun`, which carries firings.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed]
  @fields [:schedule_id]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          schedule_id: String.t() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
