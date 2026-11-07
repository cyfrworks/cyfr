# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PersonIdentity do
  @moduledoc """
  Ecto schema for the `person_identities` table (backs
  `Arca.PersonIdentities`): one row per person this home knows, beside
  their `users` row: the account they were admitted by, its identifier,
  its directory and the head this home last read.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "person_identities" do
    field :user_id, :string
    field :identifier, :string
    field :head_hash, :string
    field :directory_url, :string
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
