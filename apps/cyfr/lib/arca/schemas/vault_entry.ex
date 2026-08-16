# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.VaultEntry do
  @moduledoc """
  One external account's credential entry.

  `sealed_payload` MUST already be encrypted by the caller (Sanctum) —
  Arca stores bytes, it never sees plaintext. `binding_digest` is a cache:
  every reader derives the digest from the row's binding fields and treats
  the column as advisory, never as an authority.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "vault_entries" do
    field :athanor_id, :string
    field :name, :string
    field :provider_hint, :string, default: ""
    field :kind, :string
    field :provenance, :string, default: "user"
    field :field_names, :string, default: "[]"
    field :binding_digest, :string
    field :oauth_endpoints, :string
    field :oauth_scopes, :string
    field :status, :string, default: "active"
    field :payload_rev, :integer, default: 0
    field :sealed_payload, :binary
    field :last_used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
