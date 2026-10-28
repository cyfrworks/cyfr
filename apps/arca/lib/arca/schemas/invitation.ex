# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Invitation do
  @moduledoc """
  Ecto schema for the `invitations` table (backs `Arca.Invitations`): one
  invitation to become a person here, stored by the hash of its code,
  with its issuer's `security_generation` when they issued it
  (`issuer_generation`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "invitations" do
    field :code_hash, :string
    field :issued_by, :string
    field :issuer_generation, :integer
    field :athanor_id, :string
    field :expires_at, :utc_datetime_usec
    field :redeemed_by, :string
    field :redeemed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
