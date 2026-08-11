# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Sweeper do
  @moduledoc """
  Periodic sweeper that removes expired entries from the Arca.Cache ETS table.

  Replaces per-module cleanup timers (Session and, formerly, the MCP SSE
  buffer) with a single
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
  Run a sweep immediately: remove expired entries, then enforce the size cap
  as a backstop. Returns the number of expired entries removed.

  Both run here, off the `Arca.Cache.put/3` hot path — a request never pays for
  an O(n) eviction scan. With attacker-cardinality counters moved to
  `Cyfr.RateLimiter`, the cap is a defense-in-depth bound, not a load-bearing
  eviction path.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    table = Arca.Cache.table_name()
    now = System.monotonic_time(:millisecond)

    expired =
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

    enforce_cap(table, Arca.Cache.max_entries())
    expired
  rescue
    e in ArgumentError ->
      Logger.warning("[Arca.Cache.Sweeper] Sweep failed: #{Exception.message(e)}")
      0
  end

  # After expired rows are gone, if the table is still over the cap, drop the
  # nearest-to-expiry rows down to it. Runs at most once per interval.
  defp enforce_cap(table, max) do
    size = :ets.info(table, :size)

    if is_integer(size) and size > max do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, _value, expires_at} -> expires_at end)
      |> Enum.take(size - max)
      |> Enum.each(fn {key, _value, _expires_at} -> :ets.delete(table, key) end)
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
