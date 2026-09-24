# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RetentionSettings do
  @moduledoc """
  Ecto schema for the `retention_settings` table: one row per athanor
  holding the retention values it has set (`Arca.RetentionSettings`).

  `settings` is the RFC 8785 encoding of a map from retention key to the
  positive integer the athanor chose; a key never set is absent, and its
  kind's default stands in for it on read. `revision` rises by one with
  every patch, which lands only while the row still holds the revision
  the patch read.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "retention_settings" do
    field :athanor_id, :string, primary_key: true
    field :settings, :string
    field :revision, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
