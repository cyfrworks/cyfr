# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RateLimiter do
  @moduledoc """
  Fixed-window request rate limiting in a dedicated ETS table.

  Kept separate from `Arca.Cache` on purpose: rate-limit keys are
  client-IP-derived, so their cardinality is **attacker-controlled**. Sharing a
  bounded table with sessions, OAuth CSRF state and tool metadata let a flood of
  distinct IPs evict that security state (and forced an O(n) eviction scan on the
  hot path). Here the counters live in their own table, swept on a timer, so a
  flood is contained to counters that self-expire within their window.

  The transport plugs (`EmissaryWeb.Plugs.*RateLimit`) all share `check/3`:

      case Cyfr.RateLimiter.check(key, max, window_ms) do
        :ok -> conn
        {:deny, retry_after_seconds} -> reject(conn, retry_after_seconds)
      end

  Counters are node-local (single-node deployment; the same clustering caveat as
  the rest of the ETS-backed state). A throttle failing open on an unavailable
  table is deliberate — availability over strictness for a rate limit, unlike an
  authorization gate.
  """

  use GenServer

  require Logger

  @table :cyfr_rate_limiter
  @sweep_interval_ms :timer.minutes(1)
  # A window is at most a few minutes; a counter older than this is certainly
  # from a closed window and can be dropped.
  @stale_after_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a hit against `key` and decide whether it is within `max` per
  `window_ms`. Returns `:ok` or `{:deny, retry_after_seconds}`.
  """
  @spec check(term(), pos_integer(), pos_integer()) :: :ok | {:deny, pos_integer()}
  def check(key, max, window_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count >= max do
          {:deny, max(div(window_ms - (now - window_start), 1000), 1)}
        else
          :ets.update_counter(@table, key, {2, 1})
          :ok
        end

      _ ->
        # Absent or a closed window: start a fresh one.
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  rescue
    ArgumentError ->
      Logger.warning("[Cyfr.RateLimiter] table unavailable; allowing request")
      :ok
  end

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_after_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc false
  def table_name, do: @table

  @doc "Clear all counters. Test seam."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
