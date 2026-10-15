# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.FencedDocumentFloor do
  @moduledoc """
  Ecto schema for the `fenced_document_floors` table: one row per
  athanor, the revision floor of its fenced documents.

  `floor` is at least every revision a removed document of the athanor
  held: a removal raises it to the revision removed, and a create raises
  it by one and takes the result as the new document's revision
  (`Arca.FencedPublication`, its only writer). A removed document's
  revision is never reused.

  Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "fenced_document_floors" do
    field :athanor_id, :string, primary_key: true
    field :floor, :integer, default: 0
  end
end
