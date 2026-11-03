# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Athanor do
  @moduledoc """
  An athanor: the furnace one person runs in. It owns vault entries,
  components, consents, executions, schedules and keys; it is the
  isolation unit and the outbound principal. `owner_user_id` names its
  person, one athanor each.

  `status` is `"active"` or `"archived"` — an athanor is never deleted.
  `settings` is a JSON document owned by `Sanctum.Tenancy.Athanors`.

  `status`, `archived_at` and `security_generation` are the athanor's
  standing. An archive or a reopen writes them together in one
  transaction (`Arca.SecurityTransitions`), raising `security_generation`
  on every real change; the changesets here refuse them after birth, and
  refuse a generation at birth, which is always the column's 1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @statuses ["active", "archived"]

  @type t :: %__MODULE__{}

  schema "athanors" do
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

  def statuses, do: @statuses

  # What a row is born with. Identity fields (`id`, `owner_user_id`,
  # `created_by`) are set here and never cast again.
  @create_fields [
    :id,
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
    |> validate_required([:id, :name, :slug, :owner_user_id, :created_by])
    # The id names the athanor's storage directory (`Arca.Storage`
    # shares this grammar) — a dot or slash in an id would name a path
    # outside the athanor's own tree.
    |> validate_format(:id, Arca.Storage.athanor_id_format(),
      message: "must be alphanumeric with underscores or hyphens"
    )
    |> validate_inclusion(:status, @statuses)
    # The slug grammar is the namespace grammar: an athanor's slug is its
    # person's cyfr.run namespace.
    |> validate_format(:slug, Prima.ComponentRef.personal_slug_regex(),
      message: "must be lowercase alphanumeric with single hyphens"
    )
    |> unique_constraint(:slug)
    |> unique_constraint(:owner_user_id)
  end

  defp refuse_read_only(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
        do: add_error(changeset, field, "is read-only"),
        else: changeset
    end)
  end
end
