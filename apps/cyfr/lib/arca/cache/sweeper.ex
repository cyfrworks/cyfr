# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Sweeper do
  @moduledoc """
  Periodic sweeper that removes expired entries from the Arca.Cache ETS table.

  Replaces per-module cleanup timers (Session, SSEBuffer) with a single
  centralized sweep every 60 seconds. (Opus.RateLimiter keeps its own
  table and sweeper.)
  """

  use GenServer
  require Logger

  @sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc """
  Run a sweep immediately. Removes all expired entries from the cache table.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    table = Arca.Cache.table_name()
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {_key, _value, expires_at} = entry, count ->
        if now >= expires_at do
          :ets.delete_object(table, entry)
          count + 1
        else
          count
        end
      end,
      0,
      table
    )
  rescue
    e in ArgumentError ->
      Logger.warning("[Arca.Cache.Sweeper] Sweep failed: #{Exception.message(e)}")
      0
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
