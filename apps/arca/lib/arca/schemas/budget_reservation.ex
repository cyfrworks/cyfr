# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.BudgetReservation do
  @moduledoc """
  A root execution's invocation reservation: the cap its authority was
  minted with and how much of it is charged. `id` is the authority's
  budget id, so a rebuilt authority charges the same row. Released when
  the root ends. Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "budget_reservations" do
    field :athanor_id, :string
    field :root_execution_id, :string
    field :kind, :string, default: "invoke"
    field :cap, :integer
    field :charged, :integer, default: 0
    field :inserted_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
  end
end
