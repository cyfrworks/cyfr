# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Attention do
  @moduledoc """
  Something waiting for one person, or its leaving, on that person's own
  `Cyfr.Bus.attention/2` topic, for the stream a canvas reads
  (`attention.changes`). The kind is the waiting record's kind, or
  `removed` once it stops waiting. It references a record its owner
  keeps, by its `id`, with the record's own `label`, the time it began
  waiting (`since`) and the trusted `destination` where the person acts
  on it; it is never a second record of its own, and never an operator's
  item. A `removed` names how the item left (`outcome`, one of
  `outcomes/0`); a waiting item's is nil.
  """

  alias Cyfr.Bus.Payload

  @kinds [:approval, :confirmation, :failed_run, :failed_schedule, :file_offer, :removed]
  @outcomes [:resolved, :expired, :withdrawn]
  @fields [:id, :label, :since, :destination, :outcome]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind, :revision, :at | @fields]

  @type kind ::
          :approval | :confirmation | :failed_run | :failed_schedule | :file_offer | :removed

  @type outcome :: :resolved | :expired | :withdrawn

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          revision: non_neg_integer(),
          at: DateTime.t(),
          id: String.t() | nil,
          label: String.t() | nil,
          since: DateTime.t() | nil,
          destination: map() | nil,
          outcome: outcome() | nil
        }

  @doc "The closed union of what is waiting, and `removed` for what stopped."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  How a `removed` item left: settled by its person or its record
  (`resolved`), its time ran out (`expired`), or its record was taken
  away (`withdrawn`).
  """
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, [:revision, :at | @fields], Payload.stamped(fields), %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
