# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Message do
  @moduledoc """
  Ecto schema for the `messages` table (backs `Arca.ConversationStorage`).

  One row per thread entry, in `seq` order. `author` is a user id or one
  of the two reserved authors below (`agent_author/0`, `system_author/0`);
  `kind` is `text | approval | error | system`. An approval row carries the
  agent's proposal in `payload` and walks
  `pending → running → approved | declined | error`, with the decision in
  `resolution` and the person who made it in `resolved_by`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}
  # `tool_call`, `tool_result`, `compaction` and `turn_aborted` are the
  # turn's own rows: the loop writes them through `Aqua.Tape`.
  @kinds ~w(text approval error system tool_call tool_result compaction turn_aborted)
  @statuses ~w(pending running approved declined error expired)
  @agent_author "aqua"
  @system_author "system"

  @doc """
  The `author` of a row the assistant wrote: its reply, and the approval
  card it proposed. The tape reads it as the agent's own speech — what a
  person may say aloud from their own athanor, what a room excerpt renders
  under the assistant's name — so nothing the runner says in its own voice
  carries it.
  """
  @spec agent_author() :: String.t()
  def agent_author, do: @agent_author

  @doc """
  The `author` of a row written in the server's voice rather than the
  assistant's — a note about the turn (dropped, interrupted, a standing
  answer recorded or refused), an error, a line the runner posts on a
  person's behalf when no person's context applies. Never read as the
  agent's speech, never a person.
  """
  @spec system_author() :: String.t()
  def system_author, do: @system_author

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
    field :turn_id, :string
    field :approval_id, :string
    field :client_id, :string
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
    :inserted_at,
    :turn_id,
    :approval_id,
    :client_id
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :conversation_id, :athanor_id, :seq, :author, :kind, :inserted_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:conversation_id, :seq])
    |> unique_constraint([:conversation_id, :client_id])
    # The primary key, under the name each adapter reports it by.
    |> unique_constraint(:id, name: :messages_pkey)
    |> unique_constraint(:id, name: :messages_id_index)
  end
end
