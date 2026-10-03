# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.InstanceEntryMember do
  @moduledoc """
  One person listed in an instance entry's `listed` audience. Not an
  athanor's row: the audience is the instance's.
  """

  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "instance_entry_members" do
    field :instance_entry_id, :string
    field :user_id, :string
    field :inserted_at, :utc_datetime_usec
  end
end
