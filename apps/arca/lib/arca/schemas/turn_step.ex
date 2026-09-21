# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.TurnStep do
  @moduledoc """
  One step of a turn: orchestration state, referencing content by message
  and execution id. Owned by the athanor; written by the loop that owns the
  turn.

  A step's `purpose` is what it serves, set by the host and never by a
  model: `chat` (the turn's own work), `flush` (the silent request that
  lets the model keep notes before a summary, and the calls it proposed),
  or `compaction` (the summary request).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @purposes ["chat", "flush", "compaction"]

  schema "turn_steps" do
    field :athanor_id, :string
    field :turn_id, :string
    field :seq, :integer
    field :kind, :string
    field :purpose, :string
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
    field :result_message_id, :string
    field :proposal_digest, :string
    field :request_digest, :string
    field :usage, :string
    field :excluded, :string
    field :recovery, :string
    field :generation, :integer, default: 0
    field :cancel_requested_at, :utc_datetime_usec
    field :child_execution_id, :string
    field :error, :string
  end

  @doc "The purposes a step may serve."
  @spec purposes() :: [String.t()]
  def purposes, do: @purposes

  @doc """
  What becomes of a step that was dispatched and never closed, read from
  the row alone — the rule is `Cyfr.TurnStep.unresolved/1`, where the loop
  and the recovery table read it too. This head is the stored row's
  spelling of it and takes nothing but a step.
  """
  @spec unresolved(t()) :: :unanswered | :replay | :unknown | :uncertain
  def unresolved(%__MODULE__{} = step), do: Cyfr.TurnStep.unresolved(step)
end
