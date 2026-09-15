# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Thread do
  @moduledoc """
  Ecto schema for the `threads` table (backs `Arca.ThreadStorage`).

  A thread is the athanor's: every member reads the same thread and
  any member may send the next message. Its transcript is its messages;
  its turns are their own rows (`Arca.TurnStorage`). `orchestrator` is
  the agent the last turn addressed, `turn_seq` the cursor of the last
  human row a turn took up.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "threads" do
    field :athanor_id, :string
    field :title, :string, default: "New thread"
    field :created_by, :string
    field :orchestrator, :string
    field :turn_seq, :integer, default: 0
    field :last_message_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :athanor_id,
    :title,
    :created_by,
    :orchestrator,
    :turn_seq,
    :last_message_at
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :title, :created_by])
    |> validate_length(:title, max: 200)
  end
end
