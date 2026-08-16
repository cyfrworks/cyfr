# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Conversation do
  @moduledoc """
  Ecto schema for the `conversations` table (backs `Arca.ConversationStorage`).

  A conversation is the athanor's: every member reads the same thread and
  any member may send the next message. `history` is the provider-shape
  transcript the AQUA formula hands back at the end of a turn and takes as
  input on the next, stored as JSON text — one snapshot per turn.
  `execution_id` names the execution running the current turn, or is
  `nil` when the conversation is idle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :athanor_id, :string
    field :title, :string, default: "New conversation"
    field :created_by, :string
    field :history, :string
    field :execution_id, :string
    field :last_message_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @fields [:id, :athanor_id, :title, :created_by, :history, :execution_id, :last_message_at]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :title, :created_by])
    |> validate_length(:title, max: 200)
  end
end
