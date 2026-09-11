# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Approval do
  @moduledoc """
  A decision a person made on a card of a turn. Owned by the athanor; written by the runner for now and by
  the loop that will own the turn.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "approvals" do
    field :athanor_id, :string
    field :turn_id, :string
    field :step_id, :string
    field :message_id, :string
    field :status, :string
    field :scope, :string
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :resolution, :string
    field :inserted_at, :utc_datetime_usec
    field :proposal_digest, :string, default: ""
    field :resolution_kind, :string
    field :launch_execution_id, :string
    field :conversation_id, :string
  end
end
