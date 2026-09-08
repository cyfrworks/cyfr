# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Turn do
  @moduledoc """
  A turn: accepted work in a conversation and its state. Owned by the athanor; written by the runner for now and by
  the loop that will own the turn.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "turns" do
    field :athanor_id, :string
    field :conversation_id, :string
    field :execution_id, :string
    field :orchestrator, :string
    field :requested_by, :string
    field :status, :string
    field :error, :string
    field :accepted_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end
end
