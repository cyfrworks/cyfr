# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RegistryToken do
  @moduledoc """
  Schema for registry push tokens.

  One row per `(user_id, registry, namespace_slug)` — a user legitimately
  holds one personal-namespace token plus one per publisher membership on a
  registry.

  `credential_ciphertext` is encrypted via `Sanctum.Cipher`
  (the `:registry_token` purpose); plaintext never reaches this schema —
  encryption is applied by the caller, and this schema stores the ciphertext
  verbatim.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "registry_tokens" do
    field(:user_id, :string)
    field(:registry, :string)
    field(:namespace_slug, :string)
    field(:credential_ciphertext, :binary)
    field(:issued_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Build a changeset for a registry token row.

  `:credential_ciphertext` MUST already be encrypted by the caller via
  `Sanctum.Cipher.encrypt/2` with the `:registry_token` AAD — never pass a
  plaintext credential here.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :id,
      :user_id,
      :registry,
      :namespace_slug,
      :credential_ciphertext,
      :issued_at
    ])
    |> validate_required([
      :id,
      :user_id,
      :registry,
      :namespace_slug,
      :credential_ciphertext,
      :issued_at
    ])
    |> unique_constraint([:user_id, :registry, :namespace_slug])
  end
end
