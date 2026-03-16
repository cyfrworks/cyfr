defmodule SanctumArx.Membership do
  @moduledoc """
  Schema for organization memberships.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "memberships" do
    field :user_id, :string
    field :role, :string, default: "member"
    field :invited_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    belongs_to :org, SanctumArx.Org, type: :string
  end

  @valid_roles ["owner", "admin", "member"]

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :id,
      :user_id,
      :org_id,
      :role,
      :invited_at,
      :accepted_at,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :user_id, :org_id])
    |> validate_inclusion(:role, @valid_roles)
    |> foreign_key_constraint(:org_id)
    |> unique_constraint([:user_id, :org_id])
  end
end
