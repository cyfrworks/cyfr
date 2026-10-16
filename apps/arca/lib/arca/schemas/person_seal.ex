# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PersonSeal do
  @moduledoc """
  Ecto schema for the `person_seals` table: a person's seal at this home,
  the words and optional glyph the system layer shows first in every
  prompt. One row per person, never an athanor's and never a `users`
  column; it goes with the person's `users` row.
  """

  use Ecto.Schema

  @primary_key {:user_id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "person_seals" do
    field :text, :string
    field :glyph, :string
    field :set_at, :utc_datetime_usec
  end
end
