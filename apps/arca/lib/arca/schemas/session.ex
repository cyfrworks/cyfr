# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Session do
  @moduledoc """
  Ecto schema for the `sessions` table (backs `Arca.SessionStorage`).
  A remote person's session records the `identity_key_epoch` of the
  identity head verified when it was minted.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "sessions" do
    field :token_hash, :binary
    field :token_prefix, :string
    field :user_id, :string
    field :email, :string
    field :provider, :string
    field :expires_at, :utc_datetime_usec
    field :athanor_id, :string
    # The `key_epoch` of the identity head the session was minted under:
    # set for a remote person's session, nil for a local person's.
    field :identity_key_epoch, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
