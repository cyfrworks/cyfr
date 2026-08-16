# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ConsentProof do
  @moduledoc """
  A single-use consent proof row. `token_hash` is the sha256 of the
  minted token — the token itself is never stored, so reading this table
  cannot replay a proof. Consumed by delete; expiry is enforced on read
  and swept opportunistically.
  """

  use Ecto.Schema

  @primary_key {:token_hash, :string, autogenerate: false}
  schema "consent_proofs" do
    field :kind, :string
    field :digest, :string
    field :bindings, :string, default: "{}"
    field :athanor_id, :string
    field :expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
