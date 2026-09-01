# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.BuildRecord do
  @moduledoc """
  One build's lifecycle row. `Cyfr.BuildRecords` owns the surface —
  `Locus.MCP` writes through it and `Cyfr.Retention` prunes through it.
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
    # The id is caller-supplied, so a collision is an ordinary answer, not an
    # exception: `Cyfr.BuildRecords.record_started/3` reads it as "that id
    # belongs to another athanor" after its own tenant-scoped update missed.
    #
    # Both spellings, because `id` is the PRIMARY KEY (see the
    # 20260825 migration) and the two backends name that constraint
    # differently: Postgres reports `build_records_pkey`, SQLite the
    # index-shaped name. Declaring only the latter made this raise an
    # `Ecto.ConstraintError` on Postgres instead of answering — the one
    # thing the comment above says it must not do.
    |> unique_constraint(:id, name: "build_records_id_index")
    |> unique_constraint(:id, name: "build_records_pkey")
  end
end
