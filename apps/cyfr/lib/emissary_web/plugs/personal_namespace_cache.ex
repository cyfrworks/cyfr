# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.PersonalNamespaceCache do
  @moduledoc """
  Positive-only ETS cache of "user X has claimed a personal namespace on
  registry Y" lookups.

  Self-heals across multi-session: a user claiming on device A lets device B
  exit the claim-gate at most 30s later (next cache miss re-queries
  `CredentialStore.list_for_user/2`). No pub/sub invalidation — the miss
  cost is one DB query which is negligible at the claim-gate request volume.

  Pattern mirrors `Emissary.MCP.RunningTasks` (supervised GenServer that owns
  an ETS table created in `init/1`).
  """

  use GenServer

  @table :personal_namespace_cache
  # 30 seconds, expressed in native time units for monotonic_time arithmetic.
  @ttl_ms 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Starts the cache GenServer. Called by `Cyfr.Application`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check whether the given `{user_id, registry}` has a cached "claimed" flag.

  Returns `:hit` if the cache confirms the user has a personal namespace
  (within TTL), `:miss` otherwise. On miss, the caller is responsible for
  consulting `CredentialStore.list_for_user/2` and calling `put_claimed/2`
  on success.
  """
  @spec claimed?(String.t(), String.t()) :: :hit | :miss
  def claimed?(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    ensure_table()

    case :ets.lookup(@table, {user_id, registry}) do
      [{_key, monotonic_ms_stored}] ->
        now = System.monotonic_time(:millisecond)
        if now - monotonic_ms_stored < @ttl_ms, do: :hit, else: :miss

      [] ->
        :miss
    end
  end

  @doc "Mark the user as having claimed a personal namespace on this registry."
  @spec put_claimed(String.t(), String.t()) :: :ok
  def put_claimed(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    ensure_table()
    :ets.insert(@table, {{user_id, registry}, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Drop any cache entry for the user — used after an explicit probe re-sync."
  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    ensure_table()
    :ets.delete(@table, {user_id, registry})
    :ok
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  # Guard against requests arriving before the GenServer is up. Shouldn't
  # happen with correct supervision-tree ordering, but the defensive branch
  # keeps the app from crashing on a race at boot.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end
end
