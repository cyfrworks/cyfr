# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Membership do
  @moduledoc """
  A presence-only assignment: "user X is a member of athanor A", the
  person's seat in their own athanor.

  `scope` is `"athanor"` (the row names an athanor) or `"platform"` (the row
  names none — a platform admin, the server's operator). Membership carries
  no role: every member of an athanor is its admin.

  `status` is `"active"`. `added_by` records who wrote the row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @statuses ["active"]

  @type t :: %__MODULE__{}

  schema "memberships" do
    field :user_id, :string
    field :scope, :string, default: "athanor"
    field :status, :string, default: "active"
    field :added_by, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    belongs_to :athanor, Arca.Schemas.Athanor, type: :string
  end

  def statuses, do: @statuses

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :id,
      :user_id,
      :scope,
      :status,
      :added_by,
      :athanor_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :user_id, :scope, :status])
    |> validate_inclusion(:scope, Prima.TenancyScope.values())
    |> validate_inclusion(:status, @statuses)
    |> validate_scope_target()
    |> foreign_key_constraint(:athanor_id)
    |> unique_constraint([:user_id, :scope, :athanor_id],
      name: :memberships_assignment_index
    )
  end

  # An athanor membership names its athanor; a platform one names none.
  defp validate_scope_target(changeset) do
    case get_field(changeset, :scope) do
      "athanor" -> validate_required(changeset, [:athanor_id])
      "platform" -> put_change(changeset, :athanor_id, nil)
      _ -> changeset
    end
  end
end
