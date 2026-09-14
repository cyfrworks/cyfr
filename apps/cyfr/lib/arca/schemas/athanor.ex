# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Athanor do
  @moduledoc """
  An athanor: the furnace a person or a group runs in. It owns vault entries,
  components, consents, executions, schedules, keys and members; it is the
  isolation unit and the outbound principal.

  `kind` is `"person"` (exactly one member, its owner) or `"group"`. A
  group's `roster` is `"open"` — members may invite — or `"frozen"`: it
  takes its members at birth and never gains another, which is what a DM
  is. `pair_key` is set on a two-person frozen estate so "click Alice"
  finds the one that exists instead of minting a second.

  `status` is `"active"` or `"archived"` — an athanor is never deleted.
  `settings` is a JSON document owned by `Sanctum.Tenancy.Athanors`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @kinds ["person", "group"]
  @rosters ["open", "frozen"]
  @statuses ["active", "archived"]

  @type t :: %__MODULE__{}

  schema "athanors" do
    field :kind, :string
    field :roster, :string, default: "open"
    field :pair_key, :string
    field :name, :string
    field :slug, :string
    field :owner_user_id, :string
    field :status, :string, default: "active"
    field :archived_at, :utc_datetime_usec
    field :created_by, :string
    field :settings, :string
    field :provisioned_at, :utc_datetime_usec
    field :provisioning_failed_at, :utc_datetime_usec
    field :provisioning_failure, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def kinds, do: @kinds
  def rosters, do: @rosters
  def statuses, do: @statuses

  # What a row is born with. Identity fields (`id`, `kind`,
  # `owner_user_id`, `created_by`) are set here and never cast again.
  @create_fields [
    :id,
    :kind,
    :roster,
    :pair_key,
    :name,
    :slug,
    :owner_user_id,
    :status,
    :archived_at,
    :created_by,
    :settings,
    :provisioned_at,
    :created_at,
    :updated_at
  ]

  # What may change afterwards.
  @update_fields [:name, :slug, :status, :archived_at, :settings, :provisioned_at, :updated_at]

  def create_changeset(athanor, attrs), do: changeset(athanor, attrs, @create_fields)

  def update_changeset(athanor, attrs), do: changeset(athanor, attrs, @update_fields)

  defp changeset(athanor, attrs, fields) do
    athanor
    |> cast(attrs, fields)
    |> validate_required([:id, :kind, :name, :slug, :created_by])
    # The id names the athanor's storage directory (`Arca.Storage`
    # shares this grammar) — a dot or slash in an id would name a path
    # outside the athanor's own tree.
    |> validate_format(:id, Arca.Storage.athanor_id_format(),
      message: "must be alphanumeric with underscores or hyphens"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:roster, @rosters)
    |> validate_inclusion(:status, @statuses)
    # The slug grammar is the namespace grammar: a person's athanor slug is
    # their cyfr.run namespace, a group's slug is chosen from its name.
    |> validate_format(:slug, Sanctum.ComponentRef.personal_slug_regex(),
      message: "must be lowercase alphanumeric with single hyphens"
    )
    |> validate_owner()
    |> unique_constraint([:kind, :slug])
    |> unique_constraint(:owner_user_id)
    |> unique_constraint(:pair_key)
  end

  # A person athanor names its owner; a group has none.
  defp validate_owner(changeset) do
    case get_field(changeset, :kind) do
      "person" -> validate_required(changeset, [:owner_user_id])
      _ -> changeset
    end
  end
end
