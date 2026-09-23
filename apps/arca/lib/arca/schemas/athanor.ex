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

  `status`, `archived_at` and `security_generation` are the estate's
  standing. An archive or a reopen writes them together in one
  transaction (`Arca.SecurityTransitions`), raising `security_generation`
  on every real change; the changesets here refuse them after birth, and
  refuse a generation at birth, which is always the column's 1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @kinds ["person", "group"]
  @rosters ["open", "frozen"]
  @statuses ["active", "archived"]

  @type t :: %__MODULE__{}

  schema "athanors" do
    field(:kind, :string)
    field(:roster, :string, default: "open")
    field(:pair_key, :string)
    field(:name, :string)
    field(:slug, :string)
    field(:owner_user_id, :string)
    field(:status, :string, default: "active")
    field(:archived_at, :utc_datetime_usec)
    field(:created_by, :string)
    field(:settings, :string)
    field(:provisioned_at, :utc_datetime_usec)
    field(:provisioning_failed_at, :utc_datetime_usec)
    field(:provisioning_failure, :string)
    field(:security_generation, :integer, default: 1)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
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

  # What may change afterwards. The standing columns are not among them.
  @update_fields [:name, :slug, :settings, :provisioned_at, :updated_at]

  # Written only by `Arca.SecurityTransitions`.
  @standing_fields [:status, :archived_at, :security_generation]

  @doc "The standing columns, which no changeset writes after birth."
  def standing_fields, do: @standing_fields

  def create_changeset(athanor, attrs),
    do: changeset(athanor, attrs, @create_fields, [:security_generation])

  def update_changeset(athanor, attrs),
    do: changeset(athanor, attrs, @update_fields, @standing_fields)

  defp changeset(athanor, attrs, fields, read_only) do
    athanor
    |> cast(attrs, fields)
    |> refuse_read_only(attrs, read_only)
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
    |> validate_format(:slug, Cyfr.ComponentRef.personal_slug_regex(),
      message: "must be lowercase alphanumeric with single hyphens"
    )
    |> validate_owner()
    |> unique_constraint([:kind, :slug])
    |> unique_constraint(:owner_user_id)
    |> unique_constraint(:pair_key)
  end

  defp refuse_read_only(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
        do: add_error(changeset, field, "is read-only"),
        else: changeset
    end)
  end

  # A person athanor names its owner; a group has none.
  defp validate_owner(changeset) do
    case get_field(changeset, :kind) do
      "person" -> validate_required(changeset, [:owner_user_id])
      _ -> changeset
    end
  end
end
