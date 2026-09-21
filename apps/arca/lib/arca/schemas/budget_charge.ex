# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.BudgetCharge do
  @moduledoc """
  One charge against a reservation: the capacity one dispatch holds.
  `id` is the dispatch's own identity, so a retry of the same dispatch
  conflicts instead of charging twice; `attempt` is the authorizing
  attempt and `generation` the dispatch generation; `holder_execution_id`
  names the child that consumes the capacity, or nothing for a call
  without an execution of its own. A hold is a deadline: admission must
  land by `admit_by` (the hold barrier stamps `admitted_at`), and a
  charge with no holder is reclaimable past `holder_deadline`. Owned by
  the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "budget_charges" do
    field :athanor_id, :string
    field :reservation_id, :string
    field :attempt, :string
    field :generation, :integer, default: 0
    field :holder_execution_id, :string
    field :n, :integer
    field :runner_id, :string
    field :admit_by, :utc_datetime_usec
    field :admitted_at, :utc_datetime_usec
    field :holder_deadline, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
