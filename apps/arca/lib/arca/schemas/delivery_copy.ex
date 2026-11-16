# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DeliveryCopy do
  @moduledoc """
  Ecto schema for the `delivery_copies` table (`Arca.ConsumerReceipts.place/4`):
  where one consumer's try of one source revision is putting bytes, the
  thread and message whose blobs it copies under.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "delivery_copies" do
    field :consumer, :string, primary_key: true
    field :source_kind, :string, primary_key: true
    field :source_id, :string, primary_key: true
    field :source_revision, :string, primary_key: true
    field :athanor_id, :string
    field :thread_id, :string
    field :message_id, :string
    field :inserted_at, :utc_datetime_usec
  end
end
