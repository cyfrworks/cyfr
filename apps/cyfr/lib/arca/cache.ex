# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache do
  @moduledoc """
  ETS-backed read-through cache with TTL support.

  A valid public API for ephemeral in-memory data: services may use
  `Arca.Cache` directly for short-lived, non-persistent state.

  Attacker-cardinality state does **not** belong here — request rate-limit
  counters live in `Cyfr.RateLimiter`'s own table, so a flood cannot evict
  sessions or OAuth state from this shared one. Eviction and expiry run on
  `Arca.Cache.Sweeper`'s timer, never on the `put/3` hot path.

  For persistent data, services call the appropriate `Arca.*Storage` module directly.

  Keys are `{entity_type, id}` tuples; the tenant-keyed shapes are built by
  `Arca.Cache.Keys`, e.g.:
  - `{:component_meta, "ath_…", "catalyst:local.demo:0.1.0"}`
  - `{:wasm_bytes, "sha256:…"}`
  - `{:mcp_tool, "execution"}` (private to `Cyfr.Ops.Catalog` —
    read and written only through its `lookup/1` / `register_tool/4`)
  """

  require Logger

  @table_name :arca_cache
  @default_ttl_ms 60_000
  # A compile-time ceiling, not a knob: `compile_env` on a key no config
  # file sets is a constant that reads like something an operator can
  # tune. The byte budget in `Arca.Cache.Sweeper` is the tunable one.
  @max_entries 10_000

  @doc """
  Initialize the ETS cache table. Called from `Arca.Cache.Sweeper` — the
  table's one supervised owner — never from `Cyfr.Application.start/2`:
  the cache is a disposable read-through, re-created by the sweeper when
  it (re)starts.

  A sweeper crash therefore flushes the cache. That is harmless for a
  genuine read-through entry — a miss re-derives it — but NOT for a
  consumer that write-populates the table and would otherwise wait out its
  own refresh interval before noticing. Those consumers watch the owner
  with `monitor_owner/0`.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        # Written on hot paths (HTTP-stream chunks, session state, tool
        # catalogs) from many processes — without this, every write takes
        # a whole-table lock. The sibling limiter tables set it too.
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Monitor the process that owns the cache table.

  For the consumers that treat this table as a store rather than a
  read-through: `Cyfr.Ops.Catalog` and
  `Emissary.MCP.ResourceRegistry` write their catalogues here at boot and
  refresh them only every 23 hours. The table dies with its owner and comes
  back empty, and `get/1` turns the missing table into an ordinary miss —
  so without a monitor the whole MCP catalogue reads as "unknown tool" for
  up to a day, silently, and nothing restarts them (they are siblings of
  the sweeper under a `:one_for_one` tier).

  Returns the monitor reference, or `nil` when the table is not up yet —
  the caller retries in that case.
  """
  @spec monitor_owner() :: reference() | nil
  def monitor_owner do
    with tid when tid != :undefined <- :ets.whereis(@table_name),
         owner when is_pid(owner) <- :ets.info(tid, :owner) do
      Process.monitor(owner)
    else
      _ -> nil
    end
  end

  @doc """
  Get a cached value by key.

  Returns `{:ok, value}` if the key exists and has not expired,
  or `:miss` if the key is absent or expired.
  """
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table_name, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      Logger.warning(
        "[Arca.Cache] ETS table #{@table_name} not available during get(#{inspect(key)})"
      )

      :miss
  end

  @doc """
  Atomically get AND remove a cached value — `:ets.take/2`, one operation.

  For single-use state (OAuth pending records, one-shot tickets): a
  `get/1` followed by a separate delete leaves a window where two
  concurrent readers both see the value, which is exactly the replay the
  single-use contract exists to refuse.
  """
  @spec take(term()) :: {:ok, term()} | :miss
  def take(key) do
    case :ets.take(@table_name, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      Logger.warning(
        "[Arca.Cache] ETS table #{@table_name} not available during take(#{inspect(key)})"
      )

      :miss
  end

  @doc """
  Cache a value with the default TTL (#{@default_ttl_ms}ms).
  """
  @spec put(term(), term()) :: :ok | {:error, :cache_unavailable}
  def put(key, value), do: put(key, value, @default_ttl_ms)

  @doc """
  Cache a value with a custom TTL in milliseconds.
  """
  @spec put(term(), term(), non_neg_integer()) :: :ok | {:error, :cache_unavailable}
  def put(key, value, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    ArgumentError ->
      # Recreate through the supervised Sweeper, never from here: an
      # :ets.new in this rescue would make the CALLING request process the
      # table's owner, and the whole cache would vanish again when it exits.
      Logger.warning("[Arca.Cache] ETS table #{@table_name} missing during put, re-initializing")

      with :ok <- Arca.Cache.Sweeper.ensure_table() do
        try do
          expires_at = System.monotonic_time(:millisecond) + ttl_ms
          :ets.insert(@table_name, {key, value, expires_at})
          :ok
        rescue
          ArgumentError ->
            Logger.error(
              "[Arca.Cache] ETS table #{@table_name} re-initialization failed during put(#{inspect(key)})"
            )

            {:error, :cache_unavailable}
        end
      end
  end

  @doc """
  Match entries by key pattern, filtering out expired entries.

  The pattern is matched against the key portion of the ETS tuple.
  For example, `{:session, "user_1", :_}` matches all sessions for user_1.

  Returns a list of `{key, value}` tuples.
  """
  @spec match(term()) :: [{term(), term()}]
  def match(key_pattern) do
    now = System.monotonic_time(:millisecond)

    {active, expired} =
      :ets.match_object(@table_name, {key_pattern, :_, :_})
      |> Enum.split_with(fn {_key, _value, expires_at} -> now < expires_at end)

    # Clean up expired entries found during match
    for {key, _value, _expires_at} <- expired do
      :ets.delete(@table_name, key)
    end

    Enum.map(active, fn {key, value, _expires_at} -> {key, value} end)
  rescue
    ArgumentError ->
      Logger.warning(
        "[Arca.Cache] ETS table #{@table_name} not available during match(#{inspect(key_pattern)})"
      )

      []
  end

  @doc """
  Delete all entries matching the given key pattern.

  The pattern is matched against the key portion of the ETS tuple.
  For example, `{:session, "user_1", :_}` deletes all sessions for user_1.
  """
  @spec delete_match(term()) :: :ok
  def delete_match(key_pattern) do
    :ets.match_delete(@table_name, {key_pattern, :_, :_})
    :ok
  rescue
    ArgumentError ->
      Logger.warning(
        "[Arca.Cache] ETS table #{@table_name} not available during delete_match(#{inspect(key_pattern)})"
      )

      :ok
  end

  @doc """
  Atomically add `delta` to an existing integer entry, preserving its
  expiry. A missing entry stays missing — the next read-through
  recomputes — and a non-integer value is left untouched. Never extends
  a TTL: an expired-but-unswept entry is bumped in place and still reads
  as a miss.
  """
  @spec bump_existing(term(), integer()) :: :ok
  def bump_existing(key, delta) when is_integer(delta) do
    :ets.update_counter(@table_name, key, {2, delta})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Remove a cached value by key.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    :ets.delete(@table_name, key)
    :ok
  rescue
    ArgumentError ->
      Logger.warning(
        "[Arca.Cache] ETS table #{@table_name} not available during invalidate(#{inspect(key)})"
      )

      :ok
  end

  @doc false
  def table_name, do: @table_name

  @doc false
  def max_entries, do: @max_entries
end
