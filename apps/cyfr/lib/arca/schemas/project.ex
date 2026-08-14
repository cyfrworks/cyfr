# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Project do
  @moduledoc """
  Schema for projects within an organization.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :settings, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    belongs_to :org, Arca.Schemas.Org, type: :string
  end

  def changeset(project, attrs) do
    # Same grammar and rationale as Arca.Schemas.Org: the naming SSOT decides,
    # the store enforces.
    project
    |> cast(attrs, [:id, :org_id, :name, :slug, :settings, :created_at, :updated_at])
    |> validate_required([:id, :org_id, :name, :slug])
    |> validate_format(:slug, Sanctum.ComponentRef.personal_slug_regex(),
      message: "must be lowercase alphanumeric with single hyphens"
    )
    |> validate_length(:slug, min: 2)
    |> foreign_key_constraint(:org_id)
    |> unique_constraint([:org_id, :slug])
  end
end
