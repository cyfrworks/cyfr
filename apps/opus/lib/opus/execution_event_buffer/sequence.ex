# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionEventBuffer.Sequence do
  @moduledoc """
  One monotonic sequence per execution **stream**.

  Allocates shared sequences by root execution id across parent and nested formula emissions.

  `Opus.ExecutionEventBuffer.since/3` replays events with a sequence
  greater than the client’s last received sequence.

  The stream owns its numbering, so the counter is keyed by the id the events
  are addressed to. `next/1` is a single atomic ETS increment, which is what
  lets every emitter under one root share it without coordinating.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  The next sequence for `execution_id`, starting at 1.

  Falls back to a node-monotonic integer when the table is unavailable.
  """
  @spec next(String.t()) :: pos_integer()
  def next(execution_id) when is_binary(execution_id) do
    :ets.update_counter(@table, execution_id, {2, 1}, {execution_id, 0})
  rescue
    ArgumentError -> System.unique_integer([:positive, :monotonic])
  end

  @doc """
  Drop a finished stream's counter.

  Called from the stream's terminal push — the last event this id ever
  numbers. Not from the buffer process's death: that happens two minutes
  idle while the replay cache lives ten, and dropping the counter there
  restarted the numbering inside a live replay window.
  """
  @spec forget(String.t()) :: :ok
  def forget(execution_id) when is_binary(execution_id) do
    :ets.delete(@table, execution_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Raise the counter for `execution_id` to at least `floor` — never lower it.

  Called when a buffer process resumes from cached events: if the counter
  table restarted mid-run (tree restart) the counter would re-number from 1
  under sequences already in the replay window; flooring it to the cached
  high-water mark keeps the stream monotonic.
  """
  @spec reseed(String.t(), non_neg_integer()) :: :ok
  def reseed(execution_id, floor)
      when is_binary(execution_id) and is_integer(floor) and floor >= 0 do
    unless :ets.insert_new(@table, {execution_id, floor}) do
      :ets.select_replace(@table, [
        {{execution_id, :"$1"}, [{:<, :"$1", floor}], [{{execution_id, floor}}]}
      ])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(:ok) do
    # Written from the guest's own process on every emit, so both concurrency
    # flags — the same posture as the other hot counter tables.
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
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end
end
