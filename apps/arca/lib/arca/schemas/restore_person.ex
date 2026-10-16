# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RestorePerson do
  @moduledoc """
  Ecto schema for the `restore_people` table: one person's period after a
  declared restore, open until that person re-enables a method. Never an
  athanor's; it goes with the person's `users` row.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  schema "restore_people" do
    field :restore_id, :string, primary_key: true
    field :user_id, :string, primary_key: true
    field :open, :boolean, default: true
    field :closed_at, :utc_datetime_usec
  end
end
