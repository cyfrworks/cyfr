# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ObjectRevision do
  @moduledoc """
  Ecto schema for the `object_revisions` table: one guest object's path
  under `data/` in an athanor, keyed by the athanor and the path.

  `generation` is the last generation handed out for the path and only
  rises; `settled_generation` is the generation a read resolves to, nil
  until a first settlement; `sources` are the settled generation's
  (`Prima.Source`, canonical JSON); `deleted` and `deleted_at_generation`
  record a delete, which a settlement at or below that generation never
  undoes; `settled_at` is when the pointer last moved. Owned by the
  athanor.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "object_revisions" do
    field :athanor_id, :string, primary_key: true
    field :path, :string, primary_key: true
    field :generation, :integer
    field :settled_generation, :integer
    field :sources, :string
    field :deleted, :boolean, default: false
    field :deleted_at_generation, :integer
    field :settled_at, :utc_datetime_usec
  end
end
