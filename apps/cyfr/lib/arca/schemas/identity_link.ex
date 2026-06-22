# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.IdentityLink do
  @moduledoc """
  Schema for cross-provider identity links.

  Maps a tenant user (typically `"oidcc|<iss>|<sub>"` for generic-OIDC
  deployments) to a linked GitHub/Google identity whose `access_token` is
  usable for `cyfr.run` namespace-claim flows.

  `access_token_ciphertext` is encrypted via the configured `Sanctum.Cipher`
  (the `:identity_link_token` purpose); plaintext never leaves the
  link/unlink flow. The schema itself is storage-layer only — encryption is
  applied by the caller.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  @valid_providers ["github", "google"]

  schema "identity_links" do
    field(:user_id, :string)
    field(:provider, :string)
    field(:provider_subject, :string)
    field(:access_token_ciphertext, :binary)
    field(:linked_at, :utc_datetime_usec)
  end

  @doc """
  Build a changeset for an identity link.

  `:access_token_ciphertext` MUST already be encrypted by the caller via
  `Sanctum.Cipher.encrypt/2` with the appropriate tenant-bound AAD — this
  schema stores the ciphertext verbatim and performs no encryption itself.
  Never pass a plaintext token here.
  """
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :id,
      :user_id,
      :provider,
      :provider_subject,
      :access_token_ciphertext,
      :linked_at
    ])
    |> validate_required([:id, :user_id, :provider, :provider_subject, :linked_at])
    |> validate_inclusion(:provider, @valid_providers)
    |> unique_constraint([:user_id, :provider])
  end
end
