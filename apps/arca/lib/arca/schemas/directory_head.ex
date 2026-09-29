# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DirectoryHead do
  @moduledoc """
  Ecto schema for the `directory_heads` table (backs
  `Arca.DirectoryHeads`): this home's verified cache of one identifier's
  head, with the genesis and directory it was verified from.
  """

  use Ecto.Schema

  @primary_key {:identifier, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "directory_heads" do
    field :genesis, :binary
    field :directory_url, :string
    field :head_hash, :string
    field :key_epoch, :string
    field :state, :string
    field :verified_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
