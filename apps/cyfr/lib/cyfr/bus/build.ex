# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Build do
  @moduledoc """
  A build's lifecycle across the athanor, on `Cyfr.Bus.builds/1`: started,
  a phase reached, stopped. One build's own progress is a
  `Cyfr.Bus.Progress` on `Cyfr.Bus.progress/2`. `error` is bounded.
  """

  alias Cyfr.Bus.Payload

  @kinds [:started, :progress, :stopped]
  @fields [:build_id, :reference, :phase, :message, :status, :error]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :started | :progress | :stopped

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          build_id: String.t() | nil,
          reference: String.t() | nil,
          phase: atom() | String.t() | nil,
          message: String.t() | nil,
          status: atom() | nil,
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
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
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
