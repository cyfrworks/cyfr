# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RestorePerson do
  @moduledoc """
  Ecto schema for the `restore_people` table (written, read and closed by
  `Arca.SecurityTransitions`): one row per person a declared restore
  found, under that restore's id. While a person's row is open, their
  confirmation comes from a door this home re-authenticates or from their
  recovery kit, never from a suspended method; it closes when they
  re-enable a method, or when a platform administrator activates one for
  them. Never an athanor's: it goes with the person's `users` row.

  The table's CHECK holds `open = (closed_at IS NULL)`. On SQLite an
  untyped `false` is stored as the text `'false'`, which that CHECK
  refuses, so every write goes through this schema's typed fields.
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
