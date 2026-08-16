# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.OauthProviderCredential do
  @moduledoc """
  OAuth provider client credentials (the operator's OAuth app), one sealed
  blob per `(athanor_id, provider)`.

  `payload_ciphertext` MUST already be encrypted by the caller
  (`Sanctum.ProviderCredentials`) — Arca stores bytes, it never sees
  plaintext. The blob is JSON: `{"client_id": ..., "client_secret": ...}`
  with `client_secret` null for public OAuth clients.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "oauth_provider_credentials" do
    field :athanor_id, :string
    field :provider, :string
    field :payload_ciphertext, :binary
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end
end
