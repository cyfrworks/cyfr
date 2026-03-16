defmodule SanctumArx.Project do
  @moduledoc """
  Schema for projects within an organization.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :settings, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    belongs_to :org, SanctumArx.Org, type: :string
  end

  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:id, :org_id, :name, :slug, :settings, :created_at, :updated_at])
    |> validate_required([:id, :org_id, :name, :slug])
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens, min 2 chars"
    )
    |> foreign_key_constraint(:org_id)
    |> unique_constraint([:org_id, :slug])
  end
end
