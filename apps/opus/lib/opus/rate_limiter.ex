# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RateLimiter do
  @moduledoc """
  Rate limiting for WASM component executions.

  Enforces consented rate limits using a sliding window algorithm
  backed by a dedicated ETS table.

  ## Algorithm

  Sliding window over per-request timestamp entries:
  - Table: `:ordered_set` keyed by `{{org_id, project_id, component_ref}, ts_ms, uniq}`
  - Window: Configurable (default 1 minute)
  - `check/4` counts in-window entries with `:ets.select_count/2` and inserts
    one entry per allowed request — callers never serialize through a process.

  The GenServer only owns the table and sweeps expired entries; no request
  flows through it. Consequences, both acceptable for a rate limiter:

  - Counters reset if the limiter process restarts (the table dies with its
    owner). A dead table fails CLOSED: ETS raises, which the API converts to
    the same `:exit` a dead GenServer used to produce, so the executor's
    rate-limit chokepoint (`Opus.Executor`) denies exactly as before.
  - Concurrent checks at the limit boundary can overshoot by up to the number
    of simultaneous callers (non-atomic count-then-insert) — the same
    acceptance already documented in the transport-limit plugs.

  ## Usage

      # Check if request is allowed (rate limits are scoped per org+project)
      case Opus.RateLimiter.check("org_1", "project_1", "stripe-catalyst", %{
             rate_limit: %{requests: 50, window: "1m"}
           }) do
        {:ok, remaining} -> proceed_with_execution()
        {:error, :rate_limited, retry_after_ms} -> return_rate_limit_error()
      end

      # Reset rate limit (for testing or administrative purposes)
      :ok = Opus.RateLimiter.reset("org_1", "project_1", "stripe-catalyst")

  ## Limit Source

  The fourth argument is any map carrying a `:rate_limit` key of
  `%{requests: n, window: "1m"}` — callers pass the node's consented
  `Sanctum.Limits.rate_limit` (or a platform-config bucket like the emit
  cap). A nil map or nil `:rate_limit` means unlimited.
  """

  use GenServer

  require Logger

  @table :opus_rate_limiter

  @sweep_interval_ms 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the rate limiter GenServer (table owner and sweeper).
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

      iex> Opus.RateLimiter.check("org_1", "project_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:ok, 9}

      # After 10 requests...
      iex> Opus.RateLimiter.check("org_1", "project_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:error, :rate_limited, 45000}

  """
  @spec check(String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer() | :unlimited}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, :missing_tenant}
  def check(org_id, project_id, component_ref, limit_source) do
    with :ok <- reject_empty_org_id(org_id, "check") do
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
          key = make_key(org_id, project_id, component_ref)
          now = System.system_time(:millisecond)
          window_start = now - window_ms

          with_table(:check, fn ->
            count = count_in_window(key, window_start)

            if count >= max_requests do
              retry_after =
                case oldest_in_window(key, window_start) do
                  nil -> window_ms
                  oldest -> max(0, oldest + window_ms - now)
                end

              {:error, :rate_limited, retry_after}
            else
              entry = {{key, now, System.unique_integer([:positive])}, now + window_ms * 2}
              :ets.insert(@table, entry)
              {:ok, max_requests - count - 1}
            end
          end)
      end
    end
  end

  @doc """
  Reset rate limit counter for a project/component pair.

  Useful for testing or administrative overrides.
  """
  @spec reset(String.t(), String.t(), String.t()) :: :ok | {:error, :missing_tenant}
  def reset(org_id, project_id, component_ref) do
    with :ok <- reject_empty_org_id(org_id, "reset") do
      key = make_key(org_id, project_id, component_ref)

      with_table(:reset, fn ->
        :ets.select_delete(@table, [{{{key, :_, :_}, :_}, [], [true]}])
        :ok
      end)
    end
  end

  @doc """
  Get current rate limit status without incrementing the counter.

  Returns:
  - `{:ok, count, remaining, window_ms}` - Current status
  - `{:ok, :unlimited}` - No rate limit configured
  """
  @spec status(String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:ok, :unlimited}
          | {:error, :missing_tenant}
  def status(org_id, project_id, component_ref, limit_source) do
    with :ok <- reject_empty_org_id(org_id, "status") do
      case get_rate_limit_config(limit_source) do
        nil ->
          {:ok, :unlimited}

        {max_requests, window_ms} ->
          key = make_key(org_id, project_id, component_ref)
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
      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)

    try do
      :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    rescue
      # Table owned by another (dead) instance — nothing to sweep.
      ArgumentError -> :ok
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # A missing table means the owner process is dead (or never started). Raise
  # the same :exit shape a GenServer.call to a dead process produces, so the
  # executor's fail-closed `catch :exit` branch denies — a plain
  # ArgumentError would escape it and surface as a 500 instead.
  defp with_table(op, fun) do
    fun.()
  rescue
    ArgumentError -> exit({:noproc, {__MODULE__, op}})
  end

  defp count_in_window(key, window_start) do
    :ets.select_count(@table, [
      {{{key, :"$1", :_}, :_}, [{:>=, :"$1", window_start}], [true]}
    ])
  end

  # First in-window match in an :ordered_set is the oldest timestamp for the
  # key ({key, ts, uniq} entries iterate in ts order within a key).
  defp oldest_in_window(key, window_start) do
    spec = [{{{key, :"$1", :_}, :_}, [{:>=, :"$1", window_start}], [:"$1"]}]

    case :ets.select(@table, spec, 1) do
      {[oldest], _cont} -> oldest
      _ -> nil
    end
  end

  defp reject_empty_org_id(org_id, operation) when org_id in [nil, ""] do
    Logger.warning(
      "[RateLimiter] Empty org_id during #{operation} — rejecting to prevent " <>
        "cross-tenant rate limit collision"
    )

    {:error, :missing_tenant}
  end

  defp reject_empty_org_id(_org_id, _operation), do: :ok

  defp make_key(org_id, project_id, component_ref) do
    {org_id, project_id, component_ref}
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

  # Duration grammar is Sanctum.Limits' — one parser for every enforcement
  # window, so "1h" cannot mean an hour in one limiter and a fallback minute
  # in another. Unparseable is unparseable, never a default.
  defp parse_window(window) when is_integer(window), do: {:ok, window}

  defp parse_window(window) do
    case Sanctum.Limits.parse_duration(window) do
      {:ok, ms} ->
        {:ok, ms}

      {:error, reason} ->
        Logger.warning("[RateLimiter] invalid rate-limit window #{inspect(window)}: #{reason}")
        :error
    end
  end
end
