# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.FencedDocument do
  @moduledoc """
  Ecto schema for the `fenced_documents` table: the authoritative
  reference for a staged blob, keyed by `(athanor_id, key)`.

  `revision` is the per-row counter a fenced publication compares and
  raises by one (`Arca.FencedPublication`); `blob_key` and `digest` name
  the staged bytes that revision publishes. A document no publication has
  created reads as revision 0.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "fenced_documents" do
    field :athanor_id, :string, primary_key: true
    field :key, :string, primary_key: true
    field :revision, :integer
    field :blob_key, :string
    field :digest, :string
    timestamps(type: :utc_datetime_usec)
  end
end
