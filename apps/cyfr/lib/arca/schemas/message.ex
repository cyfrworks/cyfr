# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Message do
  @moduledoc """
  Ecto schema for the `messages` table (backs `Arca.ConversationStorage`).

  One row per thread entry, in `seq` order. `author` is a user id, `"aqua"`
  or `"system"`; `kind` is `text | approval | error | system`. An approval
  row carries the agent's proposal in `payload` and walks
  `pending → running → approved | declined | error`, with the decision in
  `resolution` and the person who made it in `resolved_by`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}
  @kinds ~w(text approval error system)
  @statuses ~w(pending running approved declined error)

  schema "messages" do
    field :conversation_id, :string
    field :athanor_id, :string
    field :seq, :integer
    field :author, :string
    field :kind, :string, default: "text"
    field :content, :string, default: ""
    field :payload, :string
    field :status, :string
    field :resolved_by, :string
    field :resolved_at, :utc_datetime_usec
    field :resolution, :string
    field :execution_id, :string
    field :inserted_at, :utc_datetime_usec
  end

  @fields [
    :id,
    :conversation_id,
    :athanor_id,
    :seq,
    :author,
    :kind,
    :content,
    :payload,
    :status,
    :resolved_by,
    :resolved_at,
    :resolution,
    :execution_id,
    :inserted_at
  ]

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :conversation_id, :athanor_id, :seq, :author, :kind, :inserted_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:conversation_id, :seq])
  end
end
