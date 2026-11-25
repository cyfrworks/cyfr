# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Program do
  @moduledoc """
  One of a person's running program sessions (`Opus.Programs.Terminal`),
  on that person's own `Cyfr.Bus.programs/2` topic: `started` once the
  service runs it, `changed` when what `Opus.Programs.running/1` reports
  of it moved (something attached or detached, it was kept or not), and
  `ended` once, with its `reason`. It carries what `running/1` answers
  and nothing a program printed or was typed.
  """

  alias Cyfr.Bus.Payload

  @kinds [:started, :changed, :ended]
  @fields [:session, :row_id, :name, :started_at, :kept, :attached, :by, :reason]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind, :revision, :at | @fields]

  @type kind :: :started | :changed | :ended

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          revision: non_neg_integer(),
          at: DateTime.t(),
          session: String.t() | nil,
          row_id: String.t() | nil,
          name: String.t() | nil,
          started_at: DateTime.t() | nil,
          kept: boolean() | nil,
          attached: boolean() | nil,
          by: :person | :aqua | :browser | nil,
          reason:
            :exited
            | :restarted
            | :closed
            | :unanswered
            | :idle
            | :row_changed
            | :standing
            | nil
        }

  @doc "The closed union of what happened to the session."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

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
