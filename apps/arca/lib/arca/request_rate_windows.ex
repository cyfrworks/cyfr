# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RequestRateWindows do
  @moduledoc """
  Pre-authentication request limits (`Arca.Schemas.RequestRateWindow`):
  one fixed window per bucket and key, counted on the database's clock and
  shared by every member of the cell, so N members admit a bound once, not
  N times.

  These limits guard requests no session stands behind (a directory's
  public writes, a pairing completion), so no athanor exists to own them:
  the existing athanor-scoped `Arca.RateWindows` is not passed a
  fabricated tenant. `claim/5` takes only the platform's own actor and a
  bucket spelled in code, an atom, never a value derived from a request.
  The key the caller names (a source address, an identifier) is untrusted
  and is stored only as its hash.

  ## A claim past its cap writes nothing

  A claim reads its window first, outside any transaction. At or past the
  cap it answers the refusal from that read and takes no write and no
  write lock, so traffic past a bound never holds SQLite's single writer,
  which lease renewal needs. Under the cap it counts in one locking
  transaction, with one conditional write that lands only while the window
  it read there still stands and is still under the cap; one that lost a
  race reads again, a bounded number of times. A window that ran out is
  replaced in place, conditionally on the start it read; a claim naming a
  different width opens a window at its own width.

  Cleanup is bounded: a claim that writes removes at most
  16 windows of its bucket that ran out more than a window ago.
  """

  import Ecto.Query

  alias Arca.Schemas.RequestRateWindow

  @rounds 3
  @cleanup_batch 16

  @doc """
  Count one request against `bucket` and `key`: at most `cap` in each
  window of `window_ms`. Answers `:ok`, or `{:error, {:rate_limited,
  retry_after_ms}}` with no write, or `{:error, :database_error}`.
  """
  @spec claim(Prima.Actor.t(), atom(), String.t(), pos_integer(), pos_integer()) ::
          :ok
          | {:error, {:rate_limited, non_neg_integer()} | :cross_tenant | :database_error}
  def claim(%Prima.Actor{scope: :platform, system: true}, bucket, key, cap, window_ms)
      when is_atom(bucket) and not is_nil(bucket) and not is_boolean(bucket) and is_binary(key) and
             key != "" and is_integer(cap) and cap > 0 and is_integer(window_ms) and
             window_ms > 0 do
    bucket = Atom.to_string(bucket)
    key_hash = Prima.Digest.sha256(key)

    Arca.Repo.Errors.with_db_rescue("Arca.RequestRateWindows.claim", fn ->
      claim_round(bucket, key_hash, cap, window_ms)
    end)
  end

  def claim(%Prima.Actor{scope: scope, system: system}, _bucket, _key, _cap, _window_ms)
      when scope != :platform or system != true,
      do: {:error, :cross_tenant}

  # ---- internals -------------------------------------------------------------

  # The refusal is a plain read: a claim at or past its cap takes neither
  # the write lock nor a write. Every other claim writes in one locking
  # transaction, deciding again on what it reads there.
  defp claim_round(bucket, key_hash, cap, window_ms) do
    now = Arca.ServerMetaStorage.now!()

    case window(bucket, key_hash) do
      %RequestRateWindow{} = row ->
        if current?(row, window_ms, now) and row.count >= cap,
          do: {:error, {:rate_limited, retry_after(row, now)}},
          else: written(bucket, key_hash, cap, window_ms)

      nil ->
        written(bucket, key_hash, cap, window_ms)
    end
  end

  defp written(bucket, key_hash, cap, window_ms) do
    {:ok, answer} =
      Arca.Repo.locking_transaction(fn -> counted(bucket, key_hash, cap, window_ms, @rounds) end)

    answer
  end

  # Contention past every round is answered as the limit, never as a pass:
  # a busy bucket is a limited bucket.
  defp counted(_bucket, _key_hash, _cap, window_ms, 0), do: {:error, {:rate_limited, window_ms}}

  defp counted(bucket, key_hash, cap, window_ms, rounds) do
    now = Arca.ServerMetaStorage.now!()

    case window(bucket, key_hash) do
      nil ->
        opened(bucket, key_hash, cap, window_ms, now, rounds)

      %RequestRateWindow{} = row ->
        cond do
          not current?(row, window_ms, now) -> rolled(row, bucket, key_hash, cap, window_ms, now, rounds)
          row.count >= cap -> {:error, {:rate_limited, retry_after(row, now)}}
          true -> incremented(row, bucket, key_hash, cap, window_ms, rounds)
        end
    end
  end

  defp window(bucket, key_hash) do
    Arca.Repo.one(
      from(w in RequestRateWindow, where: w.bucket == ^bucket and w.key_hash == ^key_hash)
    )
  end

  defp current?(%RequestRateWindow{window_ms: window_ms, window_start: start}, window_ms, now),
    do: DateTime.diff(now, start, :millisecond) < window_ms

  defp current?(_row, _window_ms, _now), do: false

  defp retry_after(row, now),
    do: max(row.window_ms - DateTime.diff(now, row.window_start, :millisecond), 0)

  defp opened(bucket, key_hash, cap, window_ms, now, rounds) do
    row = %{
      id: Prima.UUID7.generate_id("rrw"),
      bucket: bucket,
      key_hash: key_hash,
      window_start: now,
      window_ms: window_ms,
      count: 1,
      inserted_at: now,
      updated_at: now
    }

    case Arca.Repo.insert_all(RequestRateWindow, [row], on_conflict: :nothing) do
      {1, _} -> cleaned(bucket, window_ms, now)
      {0, _} -> counted(bucket, key_hash, cap, window_ms, rounds - 1)
    end
  end

  defp rolled(row, bucket, key_hash, cap, window_ms, now, rounds) do
    {count, _} =
      from(w in RequestRateWindow,
        where:
          w.id == ^row.id and w.window_start == ^row.window_start and
            w.window_ms == ^row.window_ms
      )
      |> Arca.Repo.update_all(
        set: [window_start: now, window_ms: window_ms, count: 1, updated_at: now]
      )

    if count == 1,
      do: cleaned(bucket, window_ms, now),
      else: counted(bucket, key_hash, cap, window_ms, rounds - 1)
  end

  defp incremented(row, bucket, key_hash, cap, window_ms, rounds) do
    {count, _} =
      from(w in RequestRateWindow,
        where:
          w.id == ^row.id and w.window_start == ^row.window_start and
            w.window_ms == ^row.window_ms and w.count < ^cap
      )
      |> Arca.Repo.update_all(inc: [count: 1])

    if count == 1,
      do: :ok,
      else: counted(bucket, key_hash, cap, window_ms, rounds - 1)
  end

  # At most `@cleanup_batch` windows of the bucket that ran out more than a
  # window ago go with a claim that already wrote. Only windows no wider
  # than the claim's own are judged by its width, so a wider window still
  # standing is never taken for a spent one.
  defp cleaned(bucket, window_ms, now) do
    before = DateTime.add(now, -2 * window_ms, :millisecond)

    stale =
      from(w in RequestRateWindow,
        where: w.bucket == ^bucket and w.window_ms <= ^window_ms and w.window_start < ^before,
        select: w.id,
        limit: @cleanup_batch
      )

    Arca.Repo.delete_all(from(w in RequestRateWindow, where: w.id in subquery(stale)))
    :ok
  end
end
