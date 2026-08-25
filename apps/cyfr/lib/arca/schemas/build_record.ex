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
  end
end
