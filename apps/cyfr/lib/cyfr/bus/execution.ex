# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Execution do
  @moduledoc """
  An execution's lifecycle on `Cyfr.Bus.executions/1`: admitted, completed,
  failed, or cancelled by a caller. The host's bridge builds it from the
  execution's lifecycle telemetry, taking only the fields below; `error`
  is a refusal's class and the cause it reads as (`causes/0`), never its
  sentence, which may carry a component's own words, nor an arbitrary
  term.
  """

  alias Cyfr.Bus.Payload

  @kinds [:started, :completed, :failed, :cancelled]
  @fields [
    :execution_id,
    :request_id,
    :parent_execution_id,
    :reference,
    :component_type,
    :duration_ms,
    :error
  ]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :started | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          execution_id: String.t() | nil,
          request_id: String.t() | nil,
          parent_execution_id: String.t() | nil,
          reference: String.t() | nil,
          component_type: atom() | String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          error: %{class: Prima.Refusal.class(), cause: atom()} | nil
        }

  # What each cause says of a run.
  @causes [
    failed: "The run failed.",
    cancelled: "The run was cancelled.",
    timed_out: "The run ran out of time.",
    refused: "The run was refused.",
    needs_setup: "The run needs a setup or a grant first.",
    waits_for_you: "The run waits for your confirmation.",
    rate_limited: "The run reached a limit.",
    unavailable: "Something the run needs is unavailable.",
    bad_input: "The run was given input it could not use.",
    not_found: "Something the run names was not found.",
    uncertain: "The run's outcome is uncertain."
  ]

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Every cause an error reads as, each with its readable sentence, in one
  order: the finite set a canvas lists and reads.
  """
  @spec causes() :: [{atom(), String.t()}]
  def causes, do: @causes

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `error` is a refusal's class and cause (`%{class, cause}`).
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    fields = Map.new(fields)

    fields = Payload.caused(fields, [:error])

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
