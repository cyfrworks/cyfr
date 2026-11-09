# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ThreadListed do
  @moduledoc """
  One thread in one person's list of threads, on that person's own
  `Cyfr.Bus.threads/2` topic, for the stream a canvas reads
  (`threads.changes`): the kind is `own` or `shared` with the thread's
  `title`, the display names of its `people`, its `last_activity`,
  whether it `waits_on_you` and how many of its messages are `unread` to
  the person (nil for an own thread, which keeps no read mark), or
  `removed` with its `id` once it leaves the list. Never a message, a
  person's id or an address.
  """

  alias Cyfr.Bus.Payload

  @kinds [:own, :shared, :removed]
  @fields [:id, :title, :people, :last_activity, :waits_on_you, :unread]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :own | :shared | :removed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          id: String.t() | nil,
          title: String.t() | nil,
          people: [String.t()] | nil,
          last_activity: DateTime.t() | nil,
          waits_on_you: boolean() | nil,
          unread: non_neg_integer() | nil
        }

  @doc "The closed union: the thread is the person's own or shared, or it left their list."
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
