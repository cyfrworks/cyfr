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
  the row alone:

    * `:unanswered` — a model request. It cannot be rebuilt and leaves no
      effect to judge, so it closes as an error.
    * `:replay` — a call reviewed replay-safe. It may be dispatched again.
    * `:unknown` — a call a note flush proposed. It closes with an
      `uncertain` outcome, is never replayed, and does not restrict the
      turn.
    * `:uncertain` — any other call. Its effect may have happened: it is
      marked `uncertain`, the turn stops on it, and until a new turn only
      replay-safe reads run.
  """
  @spec unresolved(t()) :: :unanswered | :replay | :unknown | :uncertain
  def unresolved(%__MODULE__{kind: "model"}), do: :unanswered
  def unresolved(%__MODULE__{recovery: "replay_safe"}), do: :replay
  def unresolved(%__MODULE__{purpose: "flush"}), do: :unknown
  def unresolved(%__MODULE__{}), do: :uncertain
end
