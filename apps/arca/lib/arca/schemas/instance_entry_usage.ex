# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.InstanceEntryUsage do
  @moduledoc """
  One day's use of an instance entry: a person's count under their
  `user_id`, or the entry's own total under the empty `user_id`. The day
  is the database's UTC date.
  """

  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "instance_entry_usage" do
    field :instance_entry_id, :string
    field :user_id, :string
    field :day, :date
    field :count, :integer, default: 0
    field :updated_at, :utc_datetime_usec
  end
end
