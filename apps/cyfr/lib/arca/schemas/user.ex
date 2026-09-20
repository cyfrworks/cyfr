# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.User do
  @moduledoc """
  A person this server knows: one row per person, written on the first
  admitted sign-in and touched on every later one.

  `id` is this server's own (`usr_…`, `id_prefix/0`) — the `user_id` the
  rest of the system carries; how an identity provider names the person is
  an `Arca.Schemas.ExternalIdentity` row. `provider` is the one they last
  signed in through. `email` is lowercased and not unique.
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

  @type t :: %__MODULE__{}

  # The prefix and the predicate are `Cyfr.PersonId`'s: the identity
  # domain mints with the one and this table refuses a row that fails the
  # other, so both read one declaration.

  @doc "The prefix every person's id carries; `Sanctum.Tenancy.Users` mints with it."
  @spec id_prefix() :: String.t()
  defdelegate id_prefix(), to: Cyfr.PersonId, as: :prefix

  @doc """
  Whether `id` is a person's — minted with the prefix above — as opposed
  to one of the server's synthetic principals (`system`, `_seed`,
  `webhook:<slug>`, …), which are never people and never have a row.
  """
  @spec person_id?(term()) :: boolean()
  defdelegate person_id?(id), to: Cyfr.PersonId, as: :person?

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
    # A person's id is minted here (`id_prefix/0`); the server's synthetic
    # principals — `system`, `_seed`, `webhook:<slug>`, … — never carry
    # it, so they can never become a `users` row.
    |> validate_change(:id, fn :id, id ->
      if person_id?(id), do: [], else: [id: "is not a person's id"]
    end)
    |> validate_inclusion(:status, @statuses)
    |> update_change(:email, &downcase/1)
    |> unique_constraint(:namespace)
    |> unique_constraint(:personal_athanor_id)
  end

  defp downcase(nil), do: nil
  defp downcase(email) when is_binary(email), do: String.downcase(email)
end
