# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Message do
  @moduledoc """
  Ecto schema for the `messages` table (backs `Arca.ThreadStorage`).

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

  # The two reserved authors are `Cyfr.Author`'s, where every side of a
  # thread reads them; the two heads below are this table's spelling.

  @doc "The `author` of a row the assistant wrote — `Cyfr.Author.agent/0`."
  @spec agent_author() :: String.t()
  defdelegate agent_author(), to: Cyfr.Author, as: :agent

  @doc """
  The `author` of a row written in the server's voice rather than the
  assistant's — `Cyfr.Author.system/0`.
  """
  @spec system_author() :: String.t()
  defdelegate system_author(), to: Cyfr.Author, as: :system

  schema "messages" do
    field :thread_id, :string
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
    :thread_id,
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
    |> validate_required([:id, :thread_id, :athanor_id, :seq, :author, :kind, :inserted_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:thread_id, :seq])
    |> unique_constraint([:thread_id, :client_id])
    # The primary key, under the name each adapter reports it by.
    |> unique_constraint(:id, name: :messages_pkey)
    |> unique_constraint(:id, name: :messages_id_index)
  end
end
