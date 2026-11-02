# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.SharedMessage do
  @moduledoc """
  Ecto schema for the `shared_messages` table (backs `Arca.SharedMessages`):
  one person's message in a shared thread, at its `seq`, with its payload
  as JSON text.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "shared_messages" do
    field :thread_id, :string
    field :seq, :integer
    field :author, :string
    field :content, :string, default: ""
    field :payload, :string
    field :inserted_at, :utc_datetime_usec
  end
end
