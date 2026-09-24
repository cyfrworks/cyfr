# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Execution do
  @moduledoc """
  An execution's lifecycle on `Cyfr.Bus.executions/1`: admitted, completed,
  failed, or cancelled by a caller. The host's bridge builds it from the
  execution's lifecycle telemetry, taking only the fields below; `error`
  is bounded, never an arbitrary term.
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
          error: atom() | String.t() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `error` is projected through `Cyfr.Bus.bounded_reason/1`.
  """
  @spec new(Cyfr.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Cyfr.Actor{} = actor, kind, fields \\ %{}) do
    fields = Map.new(fields)

    fields =
      Enum.reduce([:error], fields, fn key, acc ->
        if Map.has_key?(acc, key),
          do: Map.update!(acc, key, &Cyfr.Bus.bounded_reason/1),
          else: acc
      end)

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
