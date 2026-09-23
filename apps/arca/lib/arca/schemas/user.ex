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

  `status`, `denied_at` and `security_generation` are the person's
  standing. A deny or an allow writes them together in one transaction
  (`Arca.SecurityTransitions`), raising `security_generation` on every
  real change, so a credential issued against the generation a context
  read cannot be issued after that context's standing moved. The
  changesets here never write them after birth: `update_changeset/2`
  refuses them as read-only, and `changeset/2` refuses a generation at
  birth, which is always the column's 1.
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
    field(:email, :string)
    field(:email_verified, :boolean)
    field(:provider, :string)
    field(:display_name, :string)
    field(:namespace, :string)
    field(:personal_athanor_id, :string)
    field(:status, :string, default: "active")
    field(:prefs, :string)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:denied_at, :utc_datetime_usec)
    field(:security_generation, :integer, default: 1)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  # What a person is born with.
  @create_fields [
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
  ]

  # The standing columns: written only by `Arca.SecurityTransitions`.
  @standing_fields [:status, :denied_at, :security_generation]

  def statuses, do: @statuses

  @doc "The changeset a person is minted with."
  def changeset(user, attrs) do
    user
    |> cast(attrs, @create_fields)
    |> read_only(attrs, [:security_generation])
    |> validated()
  end

  @doc """
  The changeset an ordinary attribute update writes through. The standing
  columns are refused as read-only: they move only with a deny or an
  allow.
  """
  def update_changeset(user, attrs) do
    user
    |> cast(attrs, @create_fields -- @standing_fields)
    |> read_only(attrs, @standing_fields)
    |> validated()
  end

  defp read_only(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
        do: add_error(changeset, field, "is read-only"),
        else: changeset
    end)
  end

  defp validated(changeset) do
    changeset
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
