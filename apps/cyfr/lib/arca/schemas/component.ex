# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Component do
  @moduledoc """
  Ecto schema for the `components` table (backs `Arca.ComponentStorage`).

  `inserted_at`/`updated_at` are declared `:utc_datetime_usec` so reads are
  uniformly `%DateTime{}` even though the migration created the columns with
  default (naive) precision; the Postgres columns are widened to microsecond by
  the `align_timestamp_precision` migration.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "components" do
    field :name, :string
    field :version, :string
    field :component_type, :string
    field :description, :string
    field :tags, :string
    field :category, :string
    field :license, :string
    field :digest, :string
    field :size, :integer
    field :exports, :string
    field :manifest, :string
    field :publisher, :string
    field :publisher_id, :string
    field :source, :string
    field :signature_verified, :boolean
    field :signer_identity, :string
    field :signer_issuer, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
