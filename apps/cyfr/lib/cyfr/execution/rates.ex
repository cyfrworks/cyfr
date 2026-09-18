# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Rates do
  @moduledoc """
  Rate limiting for WASM component executions.

  Enforces consented rate limits using a sliding window algorithm
  backed by a dedicated ETS table.

  ## Algorithm

  Sliding window over per-request timestamp entries:
  - Table: `:ordered_set` keyed by `{{athanor_id, component_ref}, ts_ms, uniq}`
  - Window: Configurable (default 1 minute)
  - A bucket is one `{athanor_id, component_ref}` pair; its cap and window
    come from the consent the caller passes, on every claim.

  ## Atomic claims

  Every claim is one `GenServer.call` to the owner, and the owner is the
  table's only writer (the table is `:protected`, so no other process can
  insert or delete a row). For one claim the owner retires the bucket's
  rows older than the window, compares the bucket's count with the cap and
  inserts the row before it answers, so no two claims interleave: the count
  a claim sees already includes every claim answered before it, and N
  callers racing a cap of N-1 admit exactly N-1. `reset/2` also goes
  through the owner, so a reset cannot land between a claim's count and its
  insert. `status/3` reads the table directly under the caller's clock and
  never writes.

  The owner keeps each bucket's row count in its state, so a claim costs
  the rows it retires plus one insert, never a scan of the bucket. The
  invariant is that a bucket's count equals its rows in the table; claims,
  resets and the sweep, all in the owner, maintain it.

  A call the owner has taken is applied even if the caller stops waiting:
  a claim whose caller dies or times out is still recorded and spends a
  slot, so the failure direction is closed. Rate allowance is distinct from
  the execution slots `Cyfr.Execution.Slots` holds (`Cyfr.Slots`): nothing
  here holds, charges or releases a slot.

  ## Restart (slice H)

  The window lives in this boot's table and its owner's state. A restart of
  the owner or of the boot forgets every bucket, and the next claim starts
  from an empty window, so a restart under-enforces by at most one window
  per bucket and never over-refuses. While the owner is down a claim exits
  and every caller refuses. Slice H moves the authority to a shared row so
  the window survives a restart and is one across boots.

  ## Usage

      # Check if request is allowed (rate limits are scoped per athanor)
      case Cyfr.Execution.Rates.check("ath_1", "stripe-catalyst", %{
             rate_limit: %{requests: 50, window: "1m"}
           }) do
        {:ok, remaining} -> proceed_with_execution()
        {:error, :rate_limited, retry_after_ms} -> return_rate_limit_error()
      end

      # Reset rate limit (for testing or administrative purposes)
      :ok = Cyfr.Execution.Rates.reset("ath_1", "stripe-catalyst")

  ## Limit Source

  The third argument is any map carrying a `:rate_limit` key of
  `%{requests: n, window: "1m"}` — callers pass the node's consented
  `Cyfr.Limits.rate_limit` (or a platform-config bucket like the emit
  cap). A nil map or nil `:rate_limit` means unlimited.
  """

  use GenServer

  require Logger

  @table :cyfr_execution_rates

  @sweep_interval_ms 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the rate limiter GenServer (table owner, claim serializer and sweeper).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed under rate limits.

  Returns:
  - `{:ok, remaining}` - Request allowed, `remaining` requests left in window
  - `{:error, :rate_limited, retry_after_ms}` - Rate limit exceeded

  ## Examples

      iex> Cyfr.Execution.Rates.check("ath_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:ok, 9}

      # After 10 requests...
      iex> Cyfr.Execution.Rates.check("ath_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:error, :rate_limited, 45000}
  """
  @spec check(String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer() | :unlimited}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, :missing_tenant}
  def check(athanor_id, component_ref, limit_source) do
    claim_at(athanor_id, component_ref, limit_source, System.system_time(:millisecond))
  end

  # `check/3` at an explicit instant, for tests that pin a claim to the
  # window's edge. The instant stamps the row and bounds the window the
  # claim retires against; the claim itself is serialized in the owner all
  # the same.
  @doc false
  @spec claim_at(String.t(), String.t(), map() | nil, integer()) ::
          {:ok, non_neg_integer() | :unlimited}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, :missing_tenant}
  def claim_at(athanor_id, component_ref, limit_source, now) when is_integer(now) do
    with :ok <- reject_empty_athanor(athanor_id, "check") do
      case get_rate_limit_config(limit_source) do
        nil ->
          # No rate limit configured - allow unlimited
          {:ok, :unlimited}

        :invalid ->
          # A limit WAS configured but cannot be parsed. Substituting a
          # default window would silently rescale an enforcement value the
          # caller consented to — deny instead.
          {:error, :rate_limited, 0}

        {max_requests, window_ms} ->
          key = make_key(athanor_id, component_ref)
          call_owner(:check, {:claim, key, max_requests, window_ms, now})
      end
    end
  end

  @doc """
  Reset rate limit counter for an athanor/component pair.

  Useful for testing or administrative overrides.
  """
  @spec reset(String.t(), String.t()) :: :ok | {:error, :missing_tenant}
  def reset(athanor_id, component_ref) do
    with :ok <- reject_empty_athanor(athanor_id, "reset") do
      call_owner(:reset, {:reset, make_key(athanor_id, component_ref)})
    end
  end

  @doc """
  Get current rate limit status without incrementing the counter.

  Returns:
  - `{:ok, count, remaining, window_ms}` - Current status
  - `{:ok, :unlimited}` - No rate limit configured
  """
  @spec status(String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:ok, :unlimited}
          | {:error, :missing_tenant}
  def status(athanor_id, component_ref, limit_source) do
    with :ok <- reject_empty_athanor(athanor_id, "status") do
      case get_rate_limit_config(limit_source) do
        nil ->
          {:ok, :unlimited}

        :invalid ->
          # `check/3` denies on an unparseable consented window; status is
          # the diagnostics path and must report that state, not crash on
          # it (this was the one arm the case did not cover).
          {:ok, 0, 0, 0}

        {max_requests, window_ms} ->
          key = make_key(athanor_id, component_ref)
          now = System.system_time(:millisecond)
          window_start = now - window_ms

          with_table(:status, fn ->
            count = count_in_window(key, window_start)
            remaining = max(0, max_requests - count)
            {:ok, count, remaining, window_ms}
          end)
      end
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Guarded creation so a second, unnamed instance (used by tests to
    # exercise callbacks) doesn't crash on the existing named table.
    if :ets.whereis(@table) == :undefined do
      # Protected: the owner is the only writer, which is what makes a
      # claim's count-then-insert one step. Readers (`status/3`) stay direct.
      :ets.new(@table, [:ordered_set, :protected, :named_table, read_concurrency: true])
    end

    {:ok, %{counts: %{}, sweep: schedule_sweep()}}
  end

  @impl true
  def handle_call({:claim, key, max_requests, window_ms, now}, _from, state) do
    window_start = now - window_ms

    {reply, state} =
      with_owned_table(state, fn ->
        counts = retire(state.counts, key, window_start)
        count = Map.get(counts, key, 0)

        if count >= max_requests do
          {{:error, :rate_limited, retry_after(key, window_ms, now)}, %{state | counts: counts}}
        else
          row = {{key, now, System.unique_integer([:positive])}, now + window_ms * 2}
          :ets.insert(@table, row)
          {{:ok, max_requests - count - 1}, %{state | counts: Map.put(counts, key, count + 1)}}
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:reset, key}, _from, state) do
    {reply, state} =
      with_owned_table(state, fn ->
        :ets.select_delete(@table, [{{{key, :_, :_}, :_}, [], [true]}])
        {:ok, %{state | counts: Map.delete(state.counts, key)}}
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # One sweep chain: a sweep sent by hand (tests) replaces the pending
    # timer rather than starting a second chain beside it.
    Process.cancel_timer(state.sweep)
    now = System.system_time(:millisecond)

    {_ok, state} =
      with_owned_table(state, fn ->
        {:ok, %{state | counts: sweep_expired(state.counts, now)}}
      end)

    {:noreply, %{state | sweep: schedule_sweep()}}
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # A missing owner means a dead (or never started) limiter. The exit keeps
  # the shape `{reason, {__MODULE__, op}}` that the executor's fail-closed
  # `catch :exit` branch denies on, and that `status/3` raises for a missing
  # table. A call the owner took but did not answer in time is applied
  # anyway; the caller refuses and a slot is spent, never handed out twice.
  defp call_owner(op, request) do
    case GenServer.call(__MODULE__, request) do
      :unavailable -> exit({:noproc, {__MODULE__, op}})
      reply -> reply
    end
  catch
    :exit, {:noproc, _} -> exit({:noproc, {__MODULE__, op}})
    :exit, {:timeout, _} -> exit({:timeout, {__MODULE__, op}})
  end

  # A missing table means the owner process is dead (or never started). Raise
  # the same :exit shape a GenServer.call to a dead process produces, so the
  # executor's fail-closed `catch :exit` branch denies — a plain
  # ArgumentError would escape it and surface as a 500 instead.
  defp with_table(op, fun) do
    fun.()
  rescue
    ArgumentError -> exit({:noproc, {__MODULE__, op}})
  end

  # The owner's table can only be gone when another instance created it and
  # died; the counts then describe nothing, and the owner answers
  # `:unavailable` rather than crashing, which would take a table it does
  # own down with it.
  defp with_owned_table(state, fun) do
    fun.()
  rescue
    ArgumentError -> {:unavailable, %{state | counts: %{}}}
  end

  # Delete the bucket's rows older than the window and take them off its
  # count. Rows under a key iterate in timestamp order, so the expired ones
  # are a prefix and the walk stops at the first row still inside the
  # window: a claim pays for the rows it retires, never for the bucket.
  defp retire(counts, key, window_start) do
    case retire_prefix(key, window_start, first_row(key), 0) do
      0 -> counts
      retired -> decrement(counts, key, retired)
    end
  end

  defp retire_prefix(key, window_start, {key, ts, _uniq} = row, retired) when ts < window_start do
    :ets.delete(@table, row)
    retire_prefix(key, window_start, :ets.next(@table, row), retired + 1)
  end

  defp retire_prefix(_key, _window_start, _row, retired), do: retired

  # The bucket's oldest row, or nil: an `:ordered_set` selects in key order
  # and the bound prefix limits the traversal to the bucket's range.
  defp first_row(key) do
    case :ets.select(@table, [{{{key, :_, :_}, :_}, [], [{:element, 1, :"$_"}]}], 1) do
      {[row], _continuation} -> row
      :"$end_of_table" -> nil
    end
  end

  defp decrement(counts, key, by) do
    case Map.get(counts, key, 0) - by do
      n when n <= 0 -> Map.delete(counts, key)
      n -> Map.put(counts, key, n)
    end
  end

  # After a retire, the bucket's first row is its oldest in-window claim.
  defp retry_after(key, window_ms, now) do
    case first_row(key) do
      {^key, oldest, _uniq} -> max(0, oldest + window_ms - now)
      nil -> window_ms
    end
  end

  # Rows past their expiry (twice the window past their stamp) belong to
  # buckets nobody claims any more; drop them and their counts so a flood
  # of distinct buckets is reclaimed.
  defp sweep_expired(counts, now) do
    Enum.reduce(counts, counts, fn {key, _count}, acc ->
      spec = [{{{key, :_, :_}, :"$1"}, [{:<, :"$1", now}], [true]}]

      case :ets.select_delete(@table, spec) do
        0 -> acc
        deleted -> decrement(acc, key, deleted)
      end
    end)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp count_in_window(key, window_start) do
    :ets.select_count(@table, [
      {{{key, :"$1", :_}, :_}, [{:>=, :"$1", window_start}], [true]}
    ])
  end

  defp reject_empty_athanor(athanor_id, operation) when athanor_id in [nil, ""] do
    Logger.warning(
      "[Cyfr.Execution.Rates] Empty athanor_id during #{operation} — rejecting to prevent " <>
        "cross-tenant rate limit collision"
    )

    {:error, :missing_tenant}
  end

  defp reject_empty_athanor(_athanor_id, _operation), do: :ok

  defp make_key(athanor_id, component_ref) do
    {athanor_id, component_ref}
  end

  defp get_rate_limit_config(nil), do: nil
  defp get_rate_limit_config(%{rate_limit: nil}), do: nil

  defp get_rate_limit_config(%{rate_limit: %{requests: requests, window: window}}) do
    case parse_window(window) do
      {:ok, window_ms} -> {requests, window_ms}
      :error -> :invalid
    end
  end

  defp get_rate_limit_config(_), do: nil

  # Duration grammar is Cyfr.Limits' — one parser for every enforcement
  # window, so "1h" cannot mean an hour in one limiter and a fallback minute
  # in another. Unparseable is unparseable, never a default.
  defp parse_window(window) when is_integer(window), do: {:ok, window}

  defp parse_window(window) do
    case Cyfr.Limits.parse_duration(window) do
      {:ok, ms} ->
        {:ok, ms}

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Execution.Rates] invalid rate-limit window #{inspect(window)}: #{reason}"
        )

        :error
    end
  end
end
