# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.MemoryEndpoint do
  @moduledoc """
  One endpoint CYFR asks for who used what (`Arca.MemoryRecord`), the
  host's own row: the keeper's boot it last answered for, the rev the next
  ask follows and the machine's numbers and wall that answer carried.
  """

  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "memory_endpoints" do
    field :endpoint, :string, primary_key: true
    field :boot, :string
    field :after, :integer
    field :budget, :integer
    field :work, :integer
    field :floor, :integer
    field :used, :integer
    # The keeper's wall, as its report names it (Prima.LocusPool.t:wall/0).
    field :wall, Ecto.Enum, values: [:given, :no_room, :lacking]
    field :heard_at, :utc_datetime_usec
  end
end
