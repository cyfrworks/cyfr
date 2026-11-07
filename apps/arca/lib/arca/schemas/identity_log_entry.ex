# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.IdentityLogEntry do
  @moduledoc """
  Ecto schema for the `identity_log_entries` table (backs
  `Arca.IdentityLog`): one accepted entry of an identifier's log at its
  position, with the verified state it leaves; the genesis row carries the
  operator's tombstone (`gone_at`).
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
    field :state, :string
    field :bytes, :integer
    field :gone_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
