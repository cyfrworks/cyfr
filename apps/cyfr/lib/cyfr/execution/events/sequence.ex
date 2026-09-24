# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Events.Sequence do
  @moduledoc """
  The delta counters of an execution stream, one per durable prefix.

  A durable event is numbered by the row (`executions.event_seq`); a
  delta between two durable events rides a sub-sequence under the last
  durable number — `<durable>.<n>`, `n` starting at 1 for each new
  durable prefix — and is never replayed after a restart. The counter
  is keyed by `{execution_id, durable}`: a prefix already emitted keeps
  its count whatever is published later for an older one, and every
  emitter under one root shares the numbering. `next/2` is a single
  atomic ETS increment; `forget/1` retires every prefix of a finished
  stream.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The next delta number under `durable` for `execution_id`, starting at 1."
  @spec next(String.t(), non_neg_integer()) :: pos_integer()
  def next(execution_id, durable) when is_binary(execution_id) and is_integer(durable) do
    :ets.update_counter(@table, {execution_id, durable}, {2, 1}, {{execution_id, durable}, 0})
  rescue
    ArgumentError -> System.unique_integer([:positive, :monotonic])
  end

  @doc """
  Drop a finished stream's counters, every prefix. Called from the
  stream's terminal publication — the last event this id ever numbers.
  """
  @spec forget(String.t()) :: :ok
  def forget(execution_id) when is_binary(execution_id) do
    :ets.match_delete(@table, {{execution_id, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Raise the counter of `{execution_id, durable}` to at least `floor` —
  never lower it. A buffer resuming from its cache floors the prefix it
  last numbered, so a counter table that restarted mid-run does not
  re-number under deltas already in the replay window.
  """
  @spec reseed(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def reseed(execution_id, durable, floor)
      when is_binary(execution_id) and is_integer(durable) and is_integer(floor) and floor >= 0 do
    key = {execution_id, durable}

    unless :ets.insert_new(@table, {key, floor}) do
      :ets.select_replace(@table, [{{key, :"$1"}, [{:<, :"$1", floor}], [{{key, floor}}]}])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(:ok) do
    # Written from the guest's own process on every emit, so both
    # concurrency flags — the same posture as the other hot counter tables.
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end
end
