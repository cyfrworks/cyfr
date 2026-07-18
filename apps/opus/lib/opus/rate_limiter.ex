# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RateLimiter do
  @moduledoc """
  Rate limiting for WASM component executions.

  Enforces policy-defined rate limits using a sliding window algorithm
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
    the same `:exit` a dead GenServer used to produce, so
    `Sanctum.Policy.check_rate_limit/3` denies exactly as before.
  - Concurrent checks at the limit boundary can overshoot by up to the number
    of simultaneous callers (non-atomic count-then-insert) — the same
    acceptance already documented in the transport-limit plugs.

  ## Usage

      # Check if request is allowed (rate limits are scoped per org+project)
      case Opus.RateLimiter.check("org_1", "project_1", "stripe-catalyst", policy) do
        {:ok, remaining} -> proceed_with_execution()
        {:error, :rate_limited, retry_after_ms} -> return_rate_limit_error()
      end

      # Reset rate limit (for testing or administrative purposes)
      :ok = Opus.RateLimiter.reset("org_1", "project_1", "stripe-catalyst")

  ## Policy Integration

  Rate limits are defined in Host Policy:

      rate_limit:
        requests: 50
        window: "1m"

  """

  use GenServer

  require Logger

  @table :opus_rate_limiter

  # Default 1 minute window
  @default_window_ms 60_000

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
  def check(org_id, project_id, component_ref, policy) do
    with :ok <- reject_empty_org_id(org_id, "check") do
      case get_rate_limit_config(policy) do
        nil ->
          # No rate limit configured - allow unlimited
          {:ok, :unlimited}

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
  def status(org_id, project_id, component_ref, policy) do
    with :ok <- reject_empty_org_id(org_id, "status") do
      case get_rate_limit_config(policy) do
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
  # the same :exit shape a GenServer.call to a dead process produces, so
  # Sanctum.Policy.check_rate_limit's fail-closed `catch :exit` branch denies —
  # a plain ArgumentError would escape it and surface as a 500 instead.
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
    window_ms = parse_window(window)
    {requests, window_ms}
  end

  defp get_rate_limit_config(_), do: nil

  defp parse_window(window) when is_binary(window) do
    cond do
      String.ends_with?(window, "ms") ->
        window |> String.trim_trailing("ms") |> String.to_integer()

      String.ends_with?(window, "s") ->
        (window |> String.trim_trailing("s") |> String.to_integer()) * 1000

      String.ends_with?(window, "m") ->
        (window |> String.trim_trailing("m") |> String.to_integer()) * 60 * 1000

      String.ends_with?(window, "h") ->
        (window |> String.trim_trailing("h") |> String.to_integer()) * 60 * 60 * 1000

      true ->
        Logger.warning(
          "[RateLimiter] Unrecognized window format: #{inspect(window)}, using default #{@default_window_ms}ms"
        )

        @default_window_ms
    end
  rescue
    e in [ArgumentError] ->
      Logger.warning("[RateLimiter] parse_window failed for #{inspect(window)}: #{inspect(e)}")
      @default_window_ms
  end

  defp parse_window(window) when is_integer(window), do: window

  defp parse_window(window) do
    Logger.warning(
      "[RateLimiter] Invalid window value: #{inspect(window)}, using default #{@default_window_ms}ms"
    )

    @default_window_ms
  end
end
