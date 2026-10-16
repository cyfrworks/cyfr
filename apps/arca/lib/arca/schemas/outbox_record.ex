# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.OutboxRecord do
  @moduledoc """
  Ecto schema for the `outbox_records` table: one immutable fact a source
  transaction recorded, keyed by its source, the source's revision and the
  record's kind, with a snapshot that names no consumer.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "outbox_records" do
    field :source_kind, :string, primary_key: true
    field :source_id, :string, primary_key: true
    field :source_revision, :string, primary_key: true
    field :kind, :string, primary_key: true
    field :athanor_id, :string
    field :snapshot, :string
    field :inserted_at, :utc_datetime_usec
  end
end
