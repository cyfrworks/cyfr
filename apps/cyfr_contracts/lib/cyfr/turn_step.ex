# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TurnStep do
  @moduledoc """
  What becomes of a turn step that was dispatched and never closed.

  The rule reads the row alone — its `kind`, its `recovery` and its
  `purpose` — and two sides apply it: the loop, deciding whether to
  resume, and the recovery table, deciding whether a launch may be
  replayed. A step's stored row is the only input, so the answer is the
  same wherever it is asked.
  """

  @typedoc """
  A step's row, as the rule reads it. A stored step struct is one of
  these; so is a plain map carrying the three fields.
  """
  @type row :: %{
          optional(:kind) => String.t() | nil,
          optional(:recovery) => String.t() | nil,
          optional(:purpose) => String.t() | nil,
          optional(any()) => any()
        }

  @doc """
  What becomes of a step that was dispatched and never closed:

    * `:unanswered` — a model request. It cannot be rebuilt and leaves no
      effect to judge, so it closes as an error.
    * `:replay` — a call reviewed replay-safe. It may be dispatched again.
    * `:unknown` — a call a note flush proposed. It closes with an
      `uncertain` outcome, is never replayed, and does not restrict the
      turn.
    * `:uncertain` — any other call. Its effect may have happened: it is
      marked `uncertain`, the turn stops on it, and until a new turn only
      replay-safe reads run.

  The clauses are ordered, and the order is the rule: a model request is
  never replayed however it is marked, and `:uncertain` is the fallthrough
  — an unrecognised row is treated as though its effect may have landed,
  which is the fail-closed direction.
  """
  @spec unresolved(row()) :: :unanswered | :replay | :unknown | :uncertain
  def unresolved(%{kind: "model"}), do: :unanswered
  def unresolved(%{recovery: "replay_safe"}), do: :replay
  def unresolved(%{purpose: "flush"}), do: :unknown
  def unresolved(step) when is_map(step), do: :uncertain
end
