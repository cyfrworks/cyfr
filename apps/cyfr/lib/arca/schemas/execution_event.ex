# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ExecutionEvent do
  @moduledoc """
  A lifecycle or step-outcome event of an execution, durable. Owned by the athanor; written by the runner for now and by
  the loop that will own the turn.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "execution_events" do
    field :athanor_id, :string
    field :execution_id, :string
    field :turn_id, :string
    field :step_id, :string
    field :seq, :integer
    field :type, :string
    field :data, :string
    field :inserted_at, :utc_datetime_usec
  end
end
