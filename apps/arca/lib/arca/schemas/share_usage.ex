# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ShareUsage do
  @moduledoc """
  One day's use of a share, in its owner's athanor: a person's count under
  their `user_id`, or the share's own total under the empty `user_id`.
  The day is the database's UTC date.
  """

  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "share_usage" do
    field :athanor_id, :string
    field :share_id, :string
    field :user_id, :string
    field :day, :date
    field :count, :integer, default: 0
    field :updated_at, :utc_datetime_usec
  end
end
