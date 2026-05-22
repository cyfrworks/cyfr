# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Org do
  @moduledoc """
  Schema for organizations in the multi-tenant hierarchy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "orgs" do
    field :name, :string
    field :slug, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    has_many :projects, Sanctum.Tenancy.Project
    has_many :memberships, Sanctum.Tenancy.Membership
  end

  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:id, :name, :slug, :created_at, :updated_at])
    |> validate_required([:id, :name, :slug])
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens, min 2 chars"
    )
    |> unique_constraint(:slug)
  end
end
