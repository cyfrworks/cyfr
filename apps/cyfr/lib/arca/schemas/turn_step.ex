# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.TurnStep do
  @moduledoc """
  One step of a turn: orchestration state, referencing content by message and execution id. Owned by the athanor; written by the runner for now and by
  the loop that will own the turn.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "turn_steps" do
    field :athanor_id, :string
    field :turn_id, :string
    field :seq, :integer
    field :kind, :string
    field :idempotency_key, :string
    field :tool, :string
    field :action, :string
    field :dispatch_state, :string, default: "proposed"
    field :message_id, :string
    field :execution_id, :string
    field :approval_id, :string
    field :authority_digest, :string
    field :outcome, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end
end
