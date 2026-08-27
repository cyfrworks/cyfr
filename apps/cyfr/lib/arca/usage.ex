# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Usage do
  @moduledoc """
  The usage-cache discipline, in one place: what every tenant write does
  to the cached counters (`account/4`, called from the `Arca` facade's
  write gate), and how the two enforcement surfaces read them back —
  the athanor byte cap (`Sanctum.Tenancy.Caps`) through
  `athanor_bytes/1`, the public per-scope quota (`Opus.StorageHandler`)
  through `scope_usage/2` — under ONE TTL.

  The discipline: a successful create BUMPS the cached totals by what
  was written (an overwrite over-counts — the safe direction — until the
  entry's own TTL walks the tree afresh; `Arca.Cache.bump_existing/2`
  never extends a TTL). Deletes and failed writes DROP the entries, so
  reclaimed space is recomputed accurately and a partial write can never
  be under-counted. Read misses walk the tree once and cache the answer;
  walk failures are the caller's to map (fail-closed for a cap,
  fail-open for a backstop) and are never cached.

  `Arca.Cache.Keys` spells the key shapes; this module is their only
  reader and writer.
  """

  alias Sanctum.Context

  @ttl_ms :timer.minutes(5)

  @doc """
  Account one facade write against the cached counters — bump on a
  successful create, drop on a delete or a failed write. Called by
  `Arca`'s write gate for every mutation, so a new writer cannot forget.
  """
  @spec account(Context.t(), Arca.Storage.path(), term(), term()) :: :ok
  def account(%Context{athanor_id: athanor_id}, path, kind, result)
      when is_binary(athanor_id) and athanor_id != "" do
    if Arca.Storage.classify(path) == :tenant do
      whole = Arca.Cache.Keys.athanor_usage(athanor_id)
      scope = List.first(path)

      case {kind, result} do
        {{:create, bytes}, :ok} ->
          Arca.Cache.bump_existing(whole, bytes)

          # The per-scope pair backs the public quota. The file count bumps
          # unconditionally — an overwrite over-counts a file the same safe
          # direction the bytes over-count — and the TTL walks it true again.
          if scope do
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_bytes(athanor_id, scope), bytes)
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_files(athanor_id, scope), 1)
          end

        _delete_or_failed ->
          Arca.Cache.invalidate(whole)

          # Both scope counters go together: dropping only one would leave a
          # stale count that never recovers inside its TTL.
          if scope do
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_bytes(athanor_id, scope))
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_files(athanor_id, scope))
          end
      end
    end

    :ok
  end

  def account(_ctx, _path, _kind, _result), do: :ok

  @doc """
  The athanor's total stored bytes — cached, or one whole-tree walk on a
  miss. A walk failure is returned raw and never cached: the byte cap
  maps it fail-closed (`:storage_unverifiable`), and the next check
  walks again.
  """
  @spec athanor_bytes(Context.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def athanor_bytes(%Context{athanor_id: id} = ctx) when is_binary(id) and id != "" do
    key = Arca.Cache.Keys.athanor_usage(id)

    case Arca.Cache.get(key) do
      {:ok, bytes} when is_integer(bytes) ->
        {:ok, bytes}

      _miss ->
        case Arca.usage(ctx, []) do
          {:ok, %{bytes: bytes}} when is_integer(bytes) ->
            Arca.Cache.put(key, bytes, @ttl_ms)
            {:ok, bytes}

          {:ok, other} ->
            {:error, {:unexpected_usage, other}}

          {:error, _} = error ->
            error
        end
    end
  end

  def athanor_bytes(%Context{}), do: {:ok, 0}

  @doc """
  One tenant scope's cached `%{files:, bytes:}` — or one scope walk on a
  miss. Walk failures return raw, uncached; the public quota fails
  closed on them, the file-count backstop fails open — that asymmetry is
  the call sites' policy, not this cache's.
  """
  @spec scope_usage(Context.t(), String.t()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def scope_usage(%Context{athanor_id: athanor_id} = ctx, scope) when is_binary(scope) do
    bytes_key = Arca.Cache.Keys.scope_usage_bytes(athanor_id, scope)
    files_key = Arca.Cache.Keys.scope_usage_files(athanor_id, scope)

    with {:ok, bytes} when is_integer(bytes) <- Arca.Cache.get(bytes_key),
         {:ok, files} when is_integer(files) <- Arca.Cache.get(files_key) do
      {:ok, %{files: files, bytes: bytes}}
    else
      _miss ->
        case Arca.usage(ctx, [scope]) do
          {:ok, %{files: files, bytes: bytes} = usage} ->
            Arca.Cache.put(bytes_key, bytes, @ttl_ms)
            Arca.Cache.put(files_key, files, @ttl_ms)
            {:ok, usage}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Drop every cached counter for one athanor — the whole-tree total and
  all its scope pairs. Maintenance and test hygiene; the write path
  keeps itself coherent through `account/4`.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(athanor_id) when is_binary(athanor_id) do
    Arca.Cache.invalidate(Arca.Cache.Keys.athanor_usage(athanor_id))
    Arca.Cache.delete_match({:scope_usage, athanor_id, :_, :_})
    :ok
  end
end
