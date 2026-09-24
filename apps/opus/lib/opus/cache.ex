# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Cache do
  @moduledoc """
  The engine's own disposable state: an ETS table with an expiry per
  entry, owned by this process, which sweeps expired entries on a timer.

  Two things live here, and nothing that grants anything: the compiled
  components `Opus.ComponentCache` keys by digest, and the open streams
  `Opus.HttpStreamHandler` keys by execution and handle. A miss re-derives
  the entry; the table dies with this process and comes back empty.
  """

  use GenServer

  @table __MODULE__
  @sweep_ms :timer.minutes(1)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The entry under `key`, or `:miss` when there is none or it has expired."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Keep `value` under `key` for `ttl_ms`."
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0 do
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Every unexpired `{key, value}` whose key matches `pattern` (`:_` wildcards)."
  @spec match(term()) :: [{term(), term()}]
  def match(pattern) do
    now = System.monotonic_time(:millisecond)

    for {key, value, expires_at} <- :ets.match_object(@table, {pattern, :_, :_}),
        now < expires_at,
        do: {key, value}
  rescue
    ArgumentError -> []
  end

  @doc "Forget the entry under `key`."
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end
end
