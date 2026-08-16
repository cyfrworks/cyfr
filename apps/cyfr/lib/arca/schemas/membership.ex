# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Membership do
  @moduledoc """
  A presence-only assignment: "user X is a member of athanor A".

  `scope` is `"athanor"` (the row names an athanor) or `"platform"` (the row
  names none — a platform admin, the server's operator). Membership carries
  no role: every member of an athanor is its admin.

  `status` is `"active"` (the row names a `user_id`) or `"invited"` (the row
  names an `email` for a person who has not signed in yet; it becomes active,
  and gains the `user_id`, on their first admitted sign-in). `added_by`
  records who wrote the row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @statuses ["active", "invited"]

  schema "memberships" do
    field :user_id, :string
    field :email, :string
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
      :email,
      :scope,
      :status,
      :added_by,
      :athanor_id,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :scope, :status])
    |> validate_inclusion(:scope, Sanctum.Atoms.scopes())
    |> validate_inclusion(:status, @statuses)
    |> update_change(:email, &downcase/1)
    |> validate_scope_target()
    |> validate_principal()
    |> foreign_key_constraint(:athanor_id)
    |> unique_constraint([:user_id, :email, :scope, :athanor_id],
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

  # An active row names a person; an invited row names the address the
  # person will arrive with. Platform rows are always active.
  defp validate_principal(changeset) do
    case get_field(changeset, :status) do
      "active" ->
        changeset |> validate_required([:user_id]) |> put_change(:email, nil)

      "invited" ->
        if get_field(changeset, :scope) == "platform" do
          add_error(changeset, :status, "a platform assignment cannot be invited")
        else
          changeset |> validate_required([:email]) |> put_change(:user_id, nil)
        end

      _ ->
        changeset
    end
  end

  defp downcase(nil), do: nil
  defp downcase(email) when is_binary(email), do: String.downcase(email)
end
