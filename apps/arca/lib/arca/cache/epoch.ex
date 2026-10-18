# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Epoch do
  @moduledoc """
  Cache entries that stand only under the epoch they were derived in.

  An epoch is a value held in `Arca.Cache` under its own key, which a
  writer of what the entries are derived from replaces (`advance/1`)
  before it drops them. A deriver reads the epoch (`current/1`) before it
  reads anything it derives from and stores its entry with it
  (`put/4`); a read takes an entry only when it was stored under the
  epoch that read itself reads (`get/2`), and any other entry is a miss.
  So an entry derived from what stood before a change answers no read
  that begins after the change advanced the epoch, whenever it was
  stored; dropping entries is cleanup, never what keeps a read fresh.

  An epoch that is not held (never advanced, expired or evicted) is
  started afresh by the first reader, which only makes every entry
  stored before it a miss.
  """

  # Longer than any entry it guards lives, so an epoch that expires under
  # live entries only turns them into misses.
  @epoch_ttl_ms :timer.hours(1)

  @doc """
  The epoch under `epoch_key`, started afresh when none is held; `nil`
  for no key (a context with no athanor), under which nothing is stored
  or read.
  """
  @spec current(term() | nil) :: term() | nil
  def current(nil), do: nil

  def current(epoch_key) do
    case Arca.Cache.get(epoch_key) do
      {:ok, epoch} ->
        epoch

      :miss ->
        epoch = fresh()
        Arca.Cache.put(epoch_key, epoch, @epoch_ttl_ms)
        epoch
    end
  end

  @doc "Replace the epoch under `epoch_key`: every entry stored under an earlier one is a miss."
  @spec advance(term()) :: :ok
  def advance(epoch_key) do
    Arca.Cache.put(epoch_key, fresh(), @epoch_ttl_ms)
    :ok
  end

  @doc """
  The value stored under `key` when it was stored under `epoch`, else
  `:miss`.
  """
  @spec get(term() | nil, term() | nil) :: {:ok, term()} | :miss
  def get(nil, _epoch), do: :miss
  def get(_key, nil), do: :miss

  def get(key, epoch) do
    case Arca.Cache.get(key) do
      {:ok, {^epoch, value}} -> {:ok, value}
      _stale_or_absent -> :miss
    end
  end

  @doc "Store `value` under `key` with the `epoch` its derivation read before it began."
  @spec put(term() | nil, term() | nil, term(), non_neg_integer()) :: :ok
  def put(nil, _epoch, _value, _ttl_ms), do: :ok
  def put(_key, nil, _value, _ttl_ms), do: :ok

  def put(key, epoch, value, ttl_ms) do
    Arca.Cache.put(key, {epoch, value}, ttl_ms)
    :ok
  end

  defp fresh, do: System.unique_integer([:positive, :monotonic])
end
