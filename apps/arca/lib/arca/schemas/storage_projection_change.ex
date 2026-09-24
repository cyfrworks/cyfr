# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageProjectionChange do
  @moduledoc """
  Ecto schema for the `storage_projection_changes` table: the last change
  of one unit under a seeded root, as the domain projection of that root
  must see it.

  `generation` is the root epoch the change took. `ready` says whether the
  bytes it names are served: a publication and a repair are pending until
  their move to the served location finishes, an edit until its write
  returns, a deletion until the tenant delete returns. `source_revision`
  is the revision the change names, nil for a deletion (`tombstone`) and
  for a unit no commit has published. `acknowledged_generation` is the
  generation the projection last replaced its rows for; the change is
  pending while it is below `generation`.

  Keyed by athanor, root and unit key, the same pair `storage_units` is,
  and never a reference to it: a unit laid by hand has no unit row, and a
  deletion's evidence outlives the row it retired.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "storage_projection_changes" do
    field :athanor_id, :string
    field :root, :string
    field :unit_key, :string
    field :generation, :integer
    field :ready, :boolean, default: false
    field :source_revision, :string
    field :tombstone, :boolean, default: false
    field :acknowledged_generation, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
