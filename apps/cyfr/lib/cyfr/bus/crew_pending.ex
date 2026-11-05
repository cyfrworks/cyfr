# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.CrewPending do
  @moduledoc """
  A crew record committed in an athanor, on the global
  `Cyfr.Bus.crew_deliveries/0`: a request to a crew member, a member's
  reply, or a card it opened, published only after the transaction that
  recorded it (`Aqua.Tape`).

  It names the athanor alone and only wakes the delivery consumer
  (`Aqua.Crew`), which works the outbox records under its job claim, so
  a peer's delivery writes nothing twice and a lost one is delivered by
  the consumer's tick.
  """

  alias Cyfr.Bus.Payload

  @kinds [:pending]

  @enforce_keys [:kind, :athanor_id]
  defstruct [:kind, :athanor_id]

  @type kind :: :pending
  @type t :: %__MODULE__{kind: kind(), athanor_id: String.t()}

  @doc "The closed union: a crew record waits."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A crew record in `actor`'s athanor."
  @spec new(Prima.Actor.t()) :: t()
  def new(%Prima.Actor{} = actor) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :pending, @kinds),
      athanor_id: Payload.athanor!(actor)
    }
  end
end
