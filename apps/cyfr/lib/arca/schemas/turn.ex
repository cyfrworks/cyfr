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
    field :orchestrator, :string
    field :requested_by, :string
    field :status, :string
    field :error, :string
    field :accepted_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :parent_turn_id, :string
    field :message_id, :string
    field :root_execution_id, :string
    field :attempt, :string
    field :runner_id, :string
    field :fence, :string, default: ""
    field :recovery_attempts, :integer, default: 0
    field :profile_id, :string
    field :consent_id, :string
    field :agent_revision_digest, :string
    field :agent_capability_digest, :string
    field :budget_id, :string
    field :model, :string
    field :options, :string
    field :window_upto_seq, :integer
    field :active_ms, :integer, default: 0
    field :paused_at, :utc_datetime_usec
    field :paused_reason, :string
    field :launch_step_id, :string
  end
end
