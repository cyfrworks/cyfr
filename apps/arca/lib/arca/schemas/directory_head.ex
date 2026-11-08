# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DirectoryHead do
  @moduledoc """
  Ecto schema for the `directory_heads` table (backs
  `Arca.DirectoryHeads`): this home's verified cache of one account's
  head, with the genesis and directory it was verified from, the verified
  state the head leaves and when each of its keys was added, and
  `gone_at` once the directory answered the account gone.
  """

  use Ecto.Schema

  @primary_key {:identifier, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "directory_heads" do
    field :genesis, :binary
    field :directory_url, :string
    field :head_hash, :string
    field :state, :string
    field :keys_added, :string
    field :verified_at, :utc_datetime_usec
    field :gone_at, :utc_datetime_usec
    field :revision, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
