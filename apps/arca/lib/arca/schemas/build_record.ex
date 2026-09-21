# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.BuildRecord do
  @moduledoc """
  One build's lifecycle row. `Arca.BuildRecords` owns the surface —
  `Compendium.Builds` writes through it and `Cyfr.Retention` prunes through it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  @type t :: %__MODULE__{}

  schema "build_records" do
    field :athanor_id, :string
    field :user_id, :string
    field :reference, :string
    field :status, :string, default: "started"
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string
    field :result, :string
  end

  @fields [
    :id,
    :athanor_id,
    :user_id,
    :reference,
    :status,
    :started_at,
    :finished_at,
    :error,
    :result
  ]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :user_id, :reference, :status, :started_at])
    # Return id collisions as constraint errors for Arca.BuildRecords.
    # Declare both names reported by the adapters: Postgres uses the primary
    # key name; SQLite uses the index name.
    |> unique_constraint(:id, name: "build_records_id_index")
    |> unique_constraint(:id, name: "build_records_pkey")
  end
end
