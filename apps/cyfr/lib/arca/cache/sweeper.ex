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

  @doc """
  Recreate the cache table from THIS supervised process.

  `Arca.Cache.put/3` calls this when the table is missing. Creating the
  table from the caller instead would make that transient request process
  the table's owner — the whole cache would die again with it.
  """
  @spec ensure_table() :: :ok | {:error, :cache_unavailable}
  def ensure_table do
    GenServer.call(__MODULE__, :ensure_table)
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    Arca.Cache.init()
    {:reply, :ok, state}
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
    enforce_binary_budget(table)
    enforce_compiled_cap(table)
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

  # The entry cap counts rows, not bytes — 10k multi-MB WASM blobs is a very
  # different table than 10k session rows. Binary values get their own byte
  # budget, evicting nearest-to-expiry first. Non-binary values are left to
  # the entry cap: their real weight (NIF resources) is off-heap and
  # invisible to byte_size anyway — see enforce_compiled_cap/1.
  defp enforce_binary_budget(table) do
    budget = Application.get_env(:cyfr, :cache_max_binary_bytes, 268_435_456)

    binaries =
      :ets.foldl(
        fn
          {key, value, expires_at}, acc when is_binary(value) ->
            [{key, byte_size(value), expires_at} | acc]

          _entry, acc ->
            acc
        end,
        [],
        table
      )

    total = Enum.reduce(binaries, 0, fn {_k, size, _e}, acc -> acc + size end)

    if total > budget do
      binaries
      |> Enum.sort_by(fn {_key, _size, expires_at} -> expires_at end)
      |> Enum.reduce_while(total, fn {key, size, _expires_at}, remaining ->
        if remaining > budget do
          :ets.delete(table, key)
          {:cont, remaining - size}
        else
          {:halt, remaining}
        end
      end)
    end
  end

  # Compiled components hold Wasmex NIF resources whose memory lives off-heap
  # where byte_size cannot see it, so they get a small entry cap of their
  # own. Eviction is safe: the cache is pure (a miss recompiles), the
  # generation key prevents cross-engine reuse, and an in-flight execution
  # holding the term keeps the resource alive.
  defp enforce_compiled_cap(table) do
    cap = Application.get_env(:cyfr, :cache_max_compiled_components, 32)

    compiled =
      :ets.foldl(
        fn
          {{:compiled_component, _, _, _} = key, _value, expires_at}, acc ->
            [{key, expires_at} | acc]

          _entry, acc ->
            acc
        end,
        [],
        table
      )

    excess = length(compiled) - cap

    if excess > 0 do
      compiled
      |> Enum.sort_by(fn {_key, expires_at} -> expires_at end)
      |> Enum.take(excess)
      |> Enum.each(fn {key, _expires_at} -> :ets.delete(table, key) end)
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
