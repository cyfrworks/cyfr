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

  `kind` is `"daily"`, `"workspace"` or `"crew"`. A daily thread is the
  person's thread of one `day`, the date in their own time zone, one per
  date of the athanor. A workspace thread is one Aqua opens for a piece of
  work, with its `workspace_state` (`workspace_states/0`) and the daily
  thread's post it was `opened_from`. A crew thread is a child thread a
  crew member (`agent`) works in under the room thread `parent_id` names,
  a daily or a workspace thread, one per member per room while it stands;
  `archived_at` is when a child thread was retired, after which it admits
  nothing and the next request to its member opens a new one. Each kind
  holds its own fields and no other's, which the table's CHECK holds too.

  `read_seq` is the `seq` of the last message the person has seen; an
  athanor is one person's, so one mark per thread, moved forward only.
  `brain_session` is the brain's own opaque session for the thread, and
  `brain_generation` how many times it was forgotten: a turn keeps a
  session only under the generation it read, or the one its own forget
  raised (`Arca.TurnStorage`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @kinds ~w(daily workspace crew)
  @workspace_states ~w(open needs_you done failed)

  @doc "The `kind` vocabulary, the `threads_kind_known` check's."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The kinds a crew member's thread works under: a person's rooms."
  @spec room_kinds() :: [String.t()]
  def room_kinds, do: ~w(daily workspace)

  @doc "A workspace thread's states, the `threads_workspace_state_known` check's."
  @spec workspace_states() :: [String.t()]
  def workspace_states, do: @workspace_states

  schema "threads" do
    field :athanor_id, :string
    field :kind, :string
    field :parent_id, :string
    field :day, :date
    field :opened_from, :string
    field :workspace_state, :string
    field :read_seq, :integer, default: 0
    field :brain_session, :string
    field :brain_generation, :integer, default: 0
    field :archived_at, :utc_datetime_usec
    field :title, :string
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
    :kind,
    :parent_id,
    :day,
    :opened_from,
    :workspace_state,
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
    |> validate_required([:id, :athanor_id, :kind, :title, :created_by])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:workspace_state, @workspace_states)
    |> validate_length(:title, max: 200)
    |> validate_kind_fields()
    # One daily thread per date of an athanor, under the name each adapter
    # reports the partial index by.
    |> unique_constraint([:athanor_id, :day])
  end

  # Each kind's own fields, present on it and on no other kind.
  defp validate_kind_fields(changeset) do
    kind = get_field(changeset, :kind)

    changeset
    |> own_field(:day, kind == "daily")
    |> own_field(:workspace_state, kind == "workspace")
    |> own_field(:parent_id, kind == "crew")
    |> then(fn cs ->
      if kind != "workspace" and get_field(cs, :opened_from) != nil,
        do: add_error(cs, :opened_from, "only a workspace thread is opened from a post"),
        else: cs
    end)
  end

  defp own_field(changeset, field, true = _its_kind?) do
    if get_field(changeset, field) == nil,
      do: add_error(changeset, field, "can't be blank for this kind"),
      else: changeset
  end

  defp own_field(changeset, field, false) do
    if get_field(changeset, field) == nil,
      do: changeset,
      else: add_error(changeset, field, "belongs to another kind of thread")
  end
end
