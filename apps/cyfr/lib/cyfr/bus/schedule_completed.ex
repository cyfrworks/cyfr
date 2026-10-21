# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ScheduleCompleted do
  @moduledoc """
  A schedule's occurrence completed, on the global
  `Cyfr.Bus.schedule_completions/0`, published by the member that ran it
  only after the occurrence's close and the schedule's run record
  committed, and only while that member still held its slot.

  It names the athanor alone. A subscriber on every member hears every
  completion, and it only wakes the outcome's consumer
  (`Aqua.ScheduleNotes`), which works the outbox record the finish
  committed under its job claim, so delivery to peers creates no second
  write.
  """

  alias Cyfr.Bus.Payload

  @kinds [:completed]

  @enforce_keys [:kind, :athanor_id]
  defstruct [:kind, :athanor_id]

  @type kind :: :completed

  @type t :: %__MODULE__{kind: kind(), athanor_id: String.t()}

  @doc "The closed union: the occurrence completed."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A completion in `actor`'s athanor."
  @spec new(Prima.Actor.t()) :: t()
  def new(%Prima.Actor{} = actor) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :completed, @kinds),
      athanor_id: Payload.athanor!(actor)
    }
  end
end
