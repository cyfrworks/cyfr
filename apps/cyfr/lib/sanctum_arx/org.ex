defmodule SanctumArx.Org do
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
    field :plan, :string, default: "free"
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    has_many :projects, SanctumArx.Project
    has_many :memberships, SanctumArx.Membership
  end

  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  @valid_plans ["free", "team", "enterprise"]

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:id, :name, :slug, :plan, :created_at, :updated_at])
    |> validate_required([:id, :name, :slug])
    |> validate_format(:slug, @slug_format, message: "must be lowercase alphanumeric with hyphens, min 2 chars")
    |> validate_inclusion(:plan, @valid_plans)
    |> unique_constraint(:slug)
  end
end
