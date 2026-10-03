# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageProjectionRoot do
  @moduledoc """
  Ecto schema for the `storage_projection_roots` table: one row per
  athanor and seeded root, holding the root's epoch and the epoch its
  domain projection has acknowledged.

  `epoch` rises by one in the transaction of every publication,
  retirement, repair and edit of a unit under the root, and is the
  generation that change takes (`Arca.StorageProjectionRoots.advance!/3`).
  It is never lowered and the row is never deleted, so no two changes of
  one root, a unit deleted and recreated included, share a generation.
  `acknowledged_epoch` is the epoch up to which the projection reflects
  every change; it equals `epoch` exactly when nothing is pending.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "storage_projection_roots" do
    field :athanor_id, :string
    field :root, :string
    field :epoch, :integer
    field :acknowledged_epoch, :integer, default: 0
  end
end
