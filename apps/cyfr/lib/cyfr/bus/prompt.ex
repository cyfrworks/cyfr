# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Prompt do
  @moduledoc """
  A record that waits on its person moved, on that person's own
  `Cyfr.Bus.prompts/2` topic, for the stream `prompt.changes`
  (`Cyfr.Providers.Prompts`). The `kind` is the record's kind, one of
  `kinds/0`; the `fact` is what happened to it, one of that kind's
  `facts/1`. It carries the record's public `ref` and its `expires_at`, and
  nothing of what the record says: a surface reads the record by its ref
  from the kind's owner, under its own session.
  """

  alias Cyfr.Bus.Payload

  # Each kind's facts, in the order its record lives them. A confirmation
  # reads `confirmed` before its asker's repeat `consumed` it.
  @facts [
    confirmation: [:opened, :confirmed, :consumed, :cancelled, :voided, :expired],
    question: [:opened, :answered, :expired, :withdrawn]
  ]
  @kinds Keyword.keys(@facts)
  @fields [:ref, :expires_at]

  @enforce_keys [:athanor_id, :kind, :fact]
  defstruct [:athanor_id, :kind, :fact | @fields]

  @type kind :: :confirmation | :question

  @type fact ::
          :opened
          | :confirmed
          | :consumed
          | :cancelled
          | :voided
          | :expired
          | :answered
          | :withdrawn

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          fact: fact(),
          ref: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc "The closed union of the records a prompt is for."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "What can happen to a record of `kind`. A kind outside `kinds/0` raises."
  @spec facts(kind()) :: [fact()]
  def facts(kind), do: Keyword.fetch!(@facts, Payload.kind!(__MODULE__, kind, @kinds))

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0`, a fact
  outside its kind's `facts/1` or a field this struct does not declare
  raises.
  """
  @spec new(Prima.Actor.t(), kind(), fact(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fact, fields \\ %{}) do
    unless fact in facts(kind) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} has no #{kind} fact #{Prima.LoggerContext.shape(fact)}"
    end

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: kind,
      fact: fact
    })
  end
end
