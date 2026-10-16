# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ObjectGeneration do
  @moduledoc """
  Ecto schema for the `object_generations` table: one generation of a
  guest object's path whose object may exist, keyed by the athanor, the
  path and the generation, with the bytes its mark said the writer will
  store, the writer's source ledger as it stood at the mark
  (`Prima.Source`, canonical JSON) and when it was marked. A settlement
  made by the writer names the union of these sources and its own ledger;
  one made without it names these alone. The settled generation's row
  gives the path's visible bytes. Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "object_generations" do
    field :athanor_id, :string, primary_key: true
    field :path, :string, primary_key: true
    field :generation, :integer, primary_key: true
    field :bytes, :integer
    field :sources, :string
    field :marked_at, :utc_datetime_usec
  end
end
