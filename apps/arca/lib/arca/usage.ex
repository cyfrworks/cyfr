# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Usage do
  @moduledoc """
  The usage-cache discipline, in one place: what every tenant write does
  to the cached counters (`account/4`, called from the `Arca` facade's
  write gate), and how the two enforcement surfaces read them back —
  the athanor byte cap (`Cyfr.Caps`, the port) through
  `athanor_bytes/1`, the public per-scope quota (`Cyfr.Execution.GuestStorage`)
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

  ## What a second member of the cell sees, and for how long

  These counters are node-local, and the bump is the member's own: a write
  admitted on one member raises that member's copy and no peer's. So a
  peer's `athanor_bytes/1` reads a total that is short by whatever its
  peers have written since the peer last walked the tree, and the athanor
  byte cap it feeds (`Cyfr.Caps`, the port) can admit a write it would
  have refused. The direction is over-admission, not over-refusal, and it
  is not a stale number in a report: it is the estate growing past a cap a
  tenant consented to.

  **The bound is `ttl_ms/0` — five minutes.** An entry is never extended:
  `Arca.Cache.bump_existing/2` raises a total without touching its TTL, so
  every entry expires `ttl_ms/0` after the walk that made it, and the next
  read walks the whole tree and counts every member's writes. A member can
  therefore be short of the truth for at most one TTL, by at most what its
  peers wrote inside it.

  Nothing about this fails open by accident. An unresolved tenant is
  `{:error, :no_athanor}` and never `{:ok, 0}` — a zero would read an
  unresolved tenant as an empty estate and admit the write the cap was
  asked about — and a walk that cannot answer is returned raw and never
  cached, which the cap maps to `:storage_unverifiable` and refuses.

  What shortens the bound to one broadcast is a cell-wide invalidation:
  the member that admitted the write announces it, and every member drops
  its entry. This module does not broadcast it — a foundation below the
  host emits `:telemetry` and never touches PubSub, and the topics live in
  `Cyfr.Bus` — so the announcement is the host's to carry.
  `invalidate/1` is the landing point every member calls when it hears one,
  and the TTL above is what holds when a broadcast is lost.
  """

  @ttl_ms :timer.minutes(5)

  @doc """
  How long a cached counter stands: the ceiling on how far behind its
  peers' writes one member's copy can be. See the module doc.
  """
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Account one facade write against the cached counters — bump on a
  successful create, drop on a delete or a failed write. Called by
  `Arca`'s write gate for every mutation, so a new writer cannot forget.
  """
  @spec account(Cyfr.Actor.t(), Arca.Storage.path(), term(), term()) :: :ok
  def account(%Cyfr.Actor{athanor_id: athanor_id} = actor, path, kind, result)
      when is_binary(athanor_id) and athanor_id != "" do
    if Arca.Storage.classify(path) == :tenant do
      whole = Arca.Cache.Keys.athanor_usage(actor)
      scope = List.first(path)

      case {kind, result} do
        {{:create, bytes}, :ok} ->
          Arca.Cache.bump_existing(whole, bytes)

          # The per-scope pair backs the public quota. The file count bumps
          # unconditionally — an overwrite over-counts a file the same safe
          # direction the bytes over-count — and the TTL walks it true again.
          if scope do
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_bytes(actor, scope), bytes)
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_files(actor, scope), 1)
          end

        _delete_or_failed ->
          Arca.Cache.invalidate(whole)

          # Both scope counters go together: dropping only one would leave a
          # stale count that never recovers inside its TTL.
          if scope do
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_bytes(actor, scope))
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_files(actor, scope))
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
  @spec athanor_bytes(Cyfr.Actor.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def athanor_bytes(%Cyfr.Actor{athanor_id: id} = actor) when is_binary(id) and id != "" do
    key = Arca.Cache.Keys.athanor_usage(actor)

    case Arca.Cache.get(key) do
      {:ok, bytes} when is_integer(bytes) ->
        {:ok, bytes}

      _miss ->
        case Arca.usage(actor, []) do
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

  # An actor with no resolved athanor names no tree to walk. That is a
  # refusal, not a total of zero: answering `{:ok, 0}` would read an
  # unresolved tenant as an empty estate, and the byte cap above would
  # admit the write.
  def athanor_bytes(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  One tenant scope's cached `%{files:, bytes:}` — or one scope walk on a
  miss. Walk failures return raw, uncached; the public quota fails
  closed on them, the file-count backstop fails open — that asymmetry is
  the call sites' policy, not this cache's.
  """
  @spec scope_usage(Cyfr.Actor.t(), String.t()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def scope_usage(%Cyfr.Actor{athanor_id: athanor_id} = actor, scope)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(scope) do
    bytes_key = Arca.Cache.Keys.scope_usage_bytes(actor, scope)
    files_key = Arca.Cache.Keys.scope_usage_files(actor, scope)

    with {:ok, bytes} when is_integer(bytes) <- Arca.Cache.get(bytes_key),
         {:ok, files} when is_integer(files) <- Arca.Cache.get(files_key) do
      {:ok, %{files: files, bytes: bytes}}
    else
      _miss ->
        case Arca.usage(actor, [scope]) do
          {:ok, %{files: files, bytes: bytes} = usage} ->
            Arca.Cache.put(bytes_key, bytes, @ttl_ms)
            Arca.Cache.put(files_key, files, @ttl_ms)
            {:ok, usage}

          {:error, _} = error ->
            error
        end
    end
  end

  def scope_usage(%Cyfr.Actor{}, scope) when is_binary(scope), do: {:error, :no_athanor}

  @doc """
  Drop every cached counter for one athanor — the whole-tree total and
  all its scope pairs.

  This is also where a cell-wide invalidation lands: a member that hears
  that a peer wrote to this athanor's estate drops its copy, and its next
  read walks the tree and counts the peer's write. Without one, `ttl_ms/0`
  is the bound (see the module doc). On one member it is maintenance and
  test hygiene; the write path keeps itself coherent through `account/4`.
  """
  @spec invalidate(Cyfr.Actor.t()) :: :ok | {:error, :no_athanor}
  def invalidate(%Cyfr.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Cache.invalidate(Arca.Cache.Keys.athanor_usage(actor))
    Arca.Cache.delete_match(Arca.Cache.Keys.match_scope_usage(actor))
    :ok
  end

  def invalidate(%Cyfr.Actor{}), do: {:error, :no_athanor}
end
