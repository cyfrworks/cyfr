# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 Moonmoon69, Cyfrworks.com All Rights Reserved.

defmodule SanctumArx.IdentityLink do
  @moduledoc """
  Schema for cross-provider identity links.

  Introduced for Phase D.2 of `auth_refactor.md`: maps an Arx tenant user
  (whose `user_id` is typically `"oidcc|<iss>|<sub>"` under Lane 2
  enterprise OIDC — see §1.4) to a linked GitHub/Google identity whose
  access_token is usable for cyfr.run namespace-claim flows.

  `access_token_ciphertext` is encrypted via `Sanctum.Crypto.encrypt/2`;
  plaintext never leaves the link/unlink flow. The schema itself is
  storage-layer only — encryption happens in the Arx Shell UI (D.2b).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  @valid_providers ["github", "google"]

  schema "identity_links" do
    field :user_id, :string
    field :provider, :string
    field :provider_subject, :string
    field :access_token_ciphertext, :binary
    field :linked_at, :utc_datetime_usec
  end

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
