# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ScheduleOccurrence do
  @moduledoc """
  One occurrence of a schedule (`Arca.ScheduleOccurrences`): the time it
  was due for, the node that claimed it, the execution that started it
  and how it ended. `state` is `claimed` (taken, not yet admitted),
  `started` (an execution was admitted for it), then `completed`,
  `failed` or `uncertain`. Owned by the athanor through its schedule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "schedule_occurrences" do
    field :athanor_id, :string
    field :schedule_id, :string
    field :scheduled_for, :utc_datetime_usec
    field :state, :string
    field :execution_id, :string
    field :attempts, :integer, default: 0
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end

  @fields [
    :id,
    :athanor_id,
    :schedule_id,
    :scheduled_for,
    :state,
    :execution_id,
    :attempts,
    :claimed_by,
    :claimed_at,
    :ended_at
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :schedule_id, :scheduled_for, :state, :claimed_at])
    |> unique_constraint([:schedule_id, :scheduled_for])
  end
end
