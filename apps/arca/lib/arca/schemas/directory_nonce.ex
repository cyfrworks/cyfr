# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DirectoryNonce do
  @moduledoc """
  Ecto schema for the `directory_nonces` table (backs
  `Arca.DirectoryHandles`): the nonce of a signed registry request the
  registry beside this CYFR's directory accepted, spent once per account,
  with the request's expiry.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "directory_nonces" do
    field :identifier, :string
    field :nonce, :binary
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
