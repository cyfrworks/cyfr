defmodule Arca.Cache do
  @moduledoc """
  ETS-backed read-through cache with TTL support.

  A valid public API for ephemeral in-memory data. Services may use
  `Arca.Cache` directly for short-lived, non-persistent state such as
  rate-limit counters, MCP sessions, and SSE buffers.

  For persistent data, services must route through `Arca.MCP.handle/3`.

  Keys are `{entity_type, id}` tuples, e.g.:
  - `{:policy, "stripe-catalyst"}`
  - `{:permission, "user@example.com"}`
  - `{:session, "user_1", "sess_abc"}`
  """

  @table_name :arca_cache
  @default_ttl_ms 60_000

  @doc """
  Initialize the ETS cache table. Called from `Arca.Application.start/2`.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
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
    ArgumentError -> :miss
  end

  @doc """
  Cache a value with the default TTL (#{@default_ttl_ms}ms).
  """
  @spec put(term(), term()) :: :ok
  def put(key, value), do: put(key, value, @default_ttl_ms)

  @doc """
  Cache a value with a custom TTL in milliseconds.
  """
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    ArgumentError ->
      init()
      expires_at = System.monotonic_time(:millisecond) + ttl_ms
      :ets.insert(@table_name, {key, value, expires_at})
      :ok
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

    :ets.match_object(@table_name, {key_pattern, :_, :_})
    |> Enum.filter(fn {_key, _value, expires_at} -> now < expires_at end)
    |> Enum.map(fn {key, value, _expires_at} -> {key, value} end)
  rescue
    ArgumentError -> []
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
    ArgumentError -> :ok
  end

  @doc false
  def table_name, do: @table_name
end
