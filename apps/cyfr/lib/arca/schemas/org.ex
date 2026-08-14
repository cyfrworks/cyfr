# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Org do
  @moduledoc """
  Schema for organizations in the multi-tenant hierarchy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "orgs" do
    field :name, :string
    field :slug, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    has_many :projects, Arca.Schemas.Project
    has_many :memberships, Arca.Schemas.Membership
  end

  def changeset(org, attrs) do
    # Slug grammar comes from the naming SSOT — Arca stores rows, it does not
    # define what a valid name looks like. Note this is stricter than the old
    # local regex: consecutive hyphens are rejected, matching the personal
    # namespace grammar so any org slug remains claimable as a namespace.
    org
    |> cast(attrs, [:id, :name, :slug, :created_at, :updated_at])
    |> validate_required([:id, :name, :slug])
    |> validate_format(:slug, Sanctum.ComponentRef.personal_slug_regex(),
      message: "must be lowercase alphanumeric with single hyphens"
    )
    |> validate_length(:slug, min: 2)
    |> unique_constraint(:slug)
  end
end
