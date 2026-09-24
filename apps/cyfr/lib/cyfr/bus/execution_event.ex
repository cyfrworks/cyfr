# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ExecutionEvent do
  @moduledoc """
  One event of an execution's stream, on `Cyfr.Bus.execution_events/2`.

  A durable event is a row of `execution_events`, broadcast after its
  transaction committed; `sequence` is its number. A delta (`emit`) is
  broadcast before the write-behind buffer keeps it, the bus's one
  pre-persistence exception, numbered `<durable>.<n>` so a client that
  missed it replays from its cursor. The kind is which of the two, and
  `durable` and `delta` carry it: a durable event's `delta` is nil.

  The stream's own fields are the ones a replay yields (`event/1`), so a
  live event and a replayed one read alike; `athanor_id` is the bus's,
  and `node` names the emitting component on a guest-attributed delta.
  """

  alias Cyfr.Bus.Payload

  @kinds [:durable, :delta]
  @fields [:type, :execution_id, :sequence, :durable, :delta, :timestamp, :data, :origin, :node]
  @stream [:type, :execution_id, :sequence, :durable, :delta, :timestamp, :data, :origin]

  @enforce_keys [:athanor_id, :type, :execution_id, :sequence, :durable]
  defstruct [:athanor_id | @fields]

  @type kind :: :durable | :delta

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          type: String.t(),
          execution_id: String.t(),
          sequence: String.t(),
          durable: non_neg_integer(),
          delta: pos_integer() | nil,
          timestamp: String.t() | nil,
          data: term(),
          origin: String.t() | nil,
          node: String.t() | nil
        }

  @doc "The closed union: a durable row, or a delta under one."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  An event of `actor`'s athanor from its stream fields. A durable event
  must carry no `delta` and a delta must carry one; a kind outside
  `kinds/0` or a field this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map()) :: t()
  def new(%Prima.Actor{} = actor, kind, %{} = fields) do
    case {Payload.kind!(__MODULE__, kind, @kinds), Map.get(fields, :delta)} do
      {:durable, nil} ->
        :ok

      {:delta, n} when is_integer(n) ->
        :ok

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} #{kind} event with delta #{inspect(Map.get(fields, :delta))}"
    end

    Payload.build(__MODULE__, @fields, fields, %{athanor_id: Payload.athanor!(actor)})
  end

  @doc "The kind of `event`: `:delta` when it carries a delta number."
  @spec kind(t() | map()) :: kind()
  def kind(%{delta: n}) when is_integer(n), do: :delta
  def kind(_event), do: :durable

  @doc """
  The event as its stream carries it: the eight stream fields, and `node`
  when the delta names one — exactly what a replay yields for the same
  event.
  """
  @spec event(t()) :: map()
  def event(%__MODULE__{node: node} = event) do
    stream = Map.take(event, @stream)
    if is_nil(node), do: stream, else: Map.put(stream, :node, node)
  end
end
