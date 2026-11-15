# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ScheduleTurnDue do
  @moduledoc """
  A schedule holding a line for Aqua was claimed for one of its due
  times, on the global `Cyfr.Bus.schedule_turns/0`, published by the
  member that claimed it once the claim committed.

  It names the athanor alone. The claimed occurrence row is the record of
  the fire; this only wakes the turn consumer (`Aqua.ScheduleTurns`),
  which starts the turns of the claims its own boot holds, so a peer that
  hears it finds none of its own and writes nothing. A lost one loses
  nothing: the consumer reads its claims on a tick too.
  """

  alias Cyfr.Bus.Payload

  @kinds [:due]

  @enforce_keys [:kind, :athanor_id]
  defstruct [:kind, :athanor_id]

  @type kind :: :due

  @type t :: %__MODULE__{kind: kind(), athanor_id: String.t()}

  @doc "The closed union: a claimed Aqua line is due."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A due Aqua line in `actor`'s athanor."
  @spec new(Prima.Actor.t()) :: t()
  def new(%Prima.Actor{} = actor) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :due, @kinds),
      athanor_id: Payload.athanor!(actor)
    }
  end
end
