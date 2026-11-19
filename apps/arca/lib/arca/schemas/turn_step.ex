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
  `compaction` (the summary request), `page` (a call a page in Aqua's
  browser made, which the host proposed: its call and answer are rows of
  their own, `page_call` and `page_result`, which no model's request
  carries), or `brain` (what the host proposes for a program brain: its
  turn's `program.start`, the program's asks, and the deliveries to it).

  A step of kind `input` is one delivery to a program brain
  (`Arca.TurnStorage.carry/3`): its `action` is what it delivers (`post`,
  `answer`, or `notice`, a recovery prompt), its `message_id` the row it
  delivers, and its `idempotency_key` the session generation, the action
  and that row's id, so each is attempted once. It is `dispatched` before
  its command is written and closed once the driver answered; it is no
  call of a tool, gets no result and is never dispatched as one.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @purposes ["chat", "flush", "compaction", "page", "brain"]

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
    field :authority_digest, :string
    field :outcome, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :result_message_id, :string
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
  the row alone — the rule is `Prima.TurnStep.unresolved/1`, where the loop
  and the recovery table read it too. This head is the stored row's
  spelling of it and takes nothing but a step.
  """
  @spec unresolved(t()) :: :unanswered | :replay | :unknown | :uncertain
  def unresolved(%__MODULE__{} = step), do: Prima.TurnStep.unresolved(step)
end
