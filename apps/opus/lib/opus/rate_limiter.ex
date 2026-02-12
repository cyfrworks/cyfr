defmodule Opus.RateLimiter do
  @moduledoc """
  Rate limiting for WASM component executions.

  Enforces policy-defined rate limits using a sliding window algorithm
  backed by Arca.Cache for storage.

  ## Algorithm

  Uses a sliding window counter approach:
  - Key: `{:rate_limit, user_id, component_ref}`
  - Window: Configurable (default 1 minute)
  - Tracking: Stores timestamps of recent requests

  GenServer is retained for atomic check-and-increment (prevents race conditions).

  ## Usage

      # Check if request is allowed
      case Opus.RateLimiter.check("user_123", "stripe-catalyst", policy) do
        {:ok, remaining} -> proceed_with_execution()
        {:error, :rate_limited, retry_after_ms} -> return_rate_limit_error()
      end

      # Reset rate limit (for testing or administrative purposes)
      :ok = Opus.RateLimiter.reset("user_123", "stripe-catalyst")

  ## Policy Integration

  Rate limits are defined in Host Policy:

      rate_limit:
        requests: 50
        window: "1m"

  """

  use GenServer

  require Logger

  @default_window_ms 60_000     # Default 1 minute window

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the rate limiter GenServer.
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

      iex> Opus.RateLimiter.check("user_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:ok, 9}

      # After 10 requests...
      iex> Opus.RateLimiter.check("user_1", "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:error, :rate_limited, 45000}

  """
  @spec check(String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer() | :unlimited} | {:error, :rate_limited, non_neg_integer()}
  def check(user_id, component_ref, policy) do
    case get_rate_limit_config(policy) do
      nil ->
        # No rate limit configured - allow unlimited
        {:ok, :unlimited}

      {max_requests, window_ms} ->
        key = make_key(user_id, component_ref)
        now = System.system_time(:millisecond)
        window_start = now - window_ms

        GenServer.call(__MODULE__, {:check, key, max_requests, window_start, now, window_ms})
    end
  end

  @doc """
  Reset rate limit counter for a user/component pair.

  Useful for testing or administrative overrides.
  """
  @spec reset(String.t(), String.t()) :: :ok
  def reset(user_id, component_ref) do
    key = make_key(user_id, component_ref)
    Arca.Cache.invalidate({:rate_limit, key})
    :ok
  end

  @doc """
  Get current rate limit status without incrementing the counter.

  Returns:
  - `{:ok, count, remaining, window_ms}` - Current status
  - `{:ok, :unlimited}` - No rate limit configured
  """
  @spec status(String.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()} | {:ok, :unlimited}
  def status(user_id, component_ref, policy) do
    case get_rate_limit_config(policy) do
      nil ->
        {:ok, :unlimited}

      {max_requests, window_ms} ->
        key = make_key(user_id, component_ref)
        now = System.system_time(:millisecond)
        window_start = now - window_ms

        GenServer.call(__MODULE__, {:status, key, max_requests, window_start})
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, key, max_requests, window_start, now, window_ms}, _from, state) do
    # Get existing timestamps for this key
    timestamps = get_timestamps(key)

    # Filter to only timestamps within the window
    active_timestamps = Enum.filter(timestamps, &(&1 >= window_start))
    current_count = length(active_timestamps)

    if current_count >= max_requests do
      # Rate limited - calculate retry_after
      oldest_in_window = Enum.min(active_timestamps, fn -> now end)
      retry_after = oldest_in_window + window_ms - now

      {:reply, {:error, :rate_limited, max(0, retry_after)}, state}
    else
      # Allow request - add timestamp
      new_timestamps = [now | active_timestamps]
      # Store with TTL = 2x window to ensure cleanup
      Arca.Cache.put({:rate_limit, key}, new_timestamps, window_ms * 2)

      remaining = max_requests - current_count - 1
      {:reply, {:ok, remaining}, state}
    end
  end

  @impl true
  def handle_call({:status, key, max_requests, window_start}, _from, state) do
    timestamps = get_timestamps(key)
    active_timestamps = Enum.filter(timestamps, &(&1 >= window_start))
    current_count = length(active_timestamps)
    remaining = max(0, max_requests - current_count)
    window_ms = System.system_time(:millisecond) - window_start

    {:reply, {:ok, current_count, remaining, window_ms}, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp make_key(user_id, component_ref) do
    {user_id, component_ref}
  end

  defp get_timestamps(key) do
    case Arca.Cache.get({:rate_limit, key}) do
      {:ok, timestamps} -> timestamps
      :miss -> []
    end
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
        @default_window_ms
    end
  rescue
    _ -> @default_window_ms
  end

  defp parse_window(window) when is_integer(window), do: window
  defp parse_window(_), do: @default_window_ms
end
