# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.User do
  @moduledoc """
  A person this server knows: one row per IdP identity, written on the first
  admitted sign-in and touched on every later one.

  `id` is the provider composite (`github|https://github.com|12345`) the
  rest of the system calls `user_id`. `email` is lowercased and not unique —
  one person signing in through two configured providers is two identities.
  `namespace` is the durable copy of the cyfr.run personal namespace;
  `personal_athanor_id` names the person's own athanor once minted. `status`
  is `"active"` or `"denied"` (server-denied: sessions and keys revoked, the
  personal athanor archived). `prefs` is a JSON document (`mode`, `theme`)
  owned by `Sanctum.Tenancy.Users`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @statuses ["active", "denied"]

  schema "users" do
    field :email, :string
    field :email_verified, :boolean
    field :provider, :string
    field :display_name, :string
    field :namespace, :string
    field :personal_athanor_id, :string
    field :status, :string, default: "active"
    field :prefs, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :denied_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def statuses, do: @statuses

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :id,
      :email,
      :email_verified,
      :provider,
      :display_name,
      :namespace,
      :personal_athanor_id,
      :status,
      :prefs,
      :first_seen_at,
      :last_seen_at,
      :denied_at,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :provider, :first_seen_at, :last_seen_at])
    # A person's id is the IdP composite `provider|issuer|subject`
    # (`Sanctum.Auth.Identity.user_id/3`). The server's synthetic principals —
    # `system`, `_seed`, `webhook:<slug>`, … — never have that shape, so
    # they can never become a `users` row.
    |> validate_format(:id, ~r/^[^|]+\|[^|]+\|.+$/, message: "is not an identity")
    |> validate_inclusion(:status, @statuses)
    |> update_change(:email, &downcase/1)
    |> unique_constraint(:namespace)
    |> unique_constraint(:personal_athanor_id)
  end

  defp downcase(nil), do: nil
  defp downcase(email) when is_binary(email), do: String.downcase(email)
end
