# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Thread do
  @moduledoc """
  Ecto schema for the `threads` table (backs `Arca.ThreadStorage`).

  A thread is the athanor's, and so its person's. Its transcript is its messages;
  its turns are their own rows (`Arca.TurnStorage`). `agent` is
  the one the last turn addressed, `turn_seq` the cursor of the last
  human row a turn took up.

  `active_turn_id` is the thread's claim: which turn holds it, or nil.
  It is taken in one statement that also names the `turn_seq` the claimant
  read, so of two members reading the same thread at the same moment only
  one claim lands. The claim is the authority; a runner process on some
  node is a lookup, never evidence of ownership.

  `kind` is `"own"`, a person's thread, or `"crew"`, a child thread a crew
  member works in under the room thread `parent_id` names; `brain_session`
  is the brain's own opaque session for the thread. Crew threads are not
  built yet: `changeset/2` casts none of the three, so every thread it
  writes is `own`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @kinds ~w(own crew)

  @doc "The `kind` vocabulary, the `threads_kind_known` check's."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  schema "threads" do
    field :athanor_id, :string
    field :kind, :string, default: "own"
    field :parent_id, :string
    field :brain_session, :string
    field :title, :string, default: "New thread"
    field :created_by, :string
    field :agent, :string
    field :turn_seq, :integer, default: 0
    field :active_turn_id, :string
    field :last_message_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :athanor_id,
    :title,
    :created_by,
    :agent,
    :turn_seq,
    :active_turn_id,
    :last_message_at
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :title, :created_by])
    |> validate_length(:title, max: 200)
  end
end
