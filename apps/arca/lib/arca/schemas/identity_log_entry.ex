# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.IdentityLogEntry do
  @moduledoc """
  Ecto schema for the `identity_log_entries` table (backs
  `Arca.IdentityLog`): one accepted entry of an identifier's log at its
  position, or one refused recovery request's recorded outcome, which has
  no position.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "identity_log_entries" do
    field :identifier, :string
    field :seq, :integer
    field :kind, :string
    field :entry_hash, :string
    field :prev_hash, :string
    field :entry, :binary
    field :request_id, :string
    field :request_digest, :string
    field :outcome, :string
    field :outcome_body, :string
    field :bytes, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
