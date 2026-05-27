# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Membership do
  @moduledoc """
  A presence-only assignment: "user X is admin of scope S".

  `scope` is one of `"platform"`, `"org"`, or `"project"`. The row's existence
  grants access to that scope — there is no role tier. `org_id` is required for
  `"org"` and `"project"` scopes; `project_id` is required for `"project"`
  scope. A `"platform"` row carries neither and bypasses the tenant gate.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "memberships" do
    field :user_id, :string
    field :scope, :string, default: "project"
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    belongs_to :org, Arca.Schemas.Org, type: :string
    belongs_to :project, Arca.Schemas.Project, type: :string
  end

  @valid_scopes ["platform", "org", "project"]

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :id,
      :user_id,
      :scope,
      :org_id,
      :project_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :user_id, :scope])
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_scope_targets()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:user_id, :scope, :org_id, :project_id],
      name: :memberships_assignment_index
    )
  end

  # "org" and "project" scopes name an org; "project" scope also names a project.
  defp validate_scope_targets(changeset) do
    case get_field(changeset, :scope) do
      "org" -> validate_required(changeset, [:org_id])
      "project" -> validate_required(changeset, [:org_id, :project_id])
      _ -> changeset
    end
  end
end
