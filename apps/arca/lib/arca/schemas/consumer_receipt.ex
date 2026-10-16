# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ConsumerReceipt do
  @moduledoc """
  Ecto schema for the `consumer_receipts` table: what one consumer did with
  one source revision (`applied`, `superseded`, `conflict` or `refused`),
  written in the transaction that applied it.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "consumer_receipts" do
    field :consumer, :string, primary_key: true
    field :source_kind, :string, primary_key: true
    field :source_id, :string, primary_key: true
    field :source_revision, :string, primary_key: true
    field :athanor_id, :string
    field :outcome, :string
    field :inserted_at, :utc_datetime_usec
  end
end
