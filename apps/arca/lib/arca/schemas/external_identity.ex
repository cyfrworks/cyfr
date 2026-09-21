# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ExternalIdentity do
  @moduledoc """
  How an identity provider names a person this server knows: one row per
  IdP identity, keyed by the composite `<provider>|<issuer>|<subject>`
  (`Sanctum.Auth.Identity.key/3`) and pointing at the person's `users`
  row. A person may be named by several; an identity names one person.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "external_identities" do
    field :user_id, :string
    field :key, :string
    field :provider, :string
    field :issuer, :string
    field :subject, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :id,
      :user_id,
      :key,
      :provider,
      :issuer,
      :subject,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_required([
      :id,
      :user_id,
      :key,
      :provider,
      :issuer,
      :subject,
      :first_seen_at,
      :last_seen_at
    ])
    |> unique_constraint(:key)
  end
end
