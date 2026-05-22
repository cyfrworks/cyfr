# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.MetricsAggregator do
  @moduledoc """
  In-memory ring of recent MCP request samples for live cockpit views.

  Attaches to `[:cyfr, :emissary, :request]` telemetry and retains the last
  15 minutes of `{ts_ms, tool, action, status, duration_ms}` tuples.

  Public API:

    * `latencies/1` — count + p50/p95/p99 over a window (default 60 s).
    * `error_buckets/2` — per-bucket error counts for sparklines (default
      60 buckets × 60 s = 1 hour).

  Memory is bounded by the time window. Telemetry attach is global so this
  works in both single-tenant and tenant-scoped deployments without
  per-tenant aggregators.
  """

  use GenServer

  @window_ms 15 * 60 * 1000
  @prune_interval_ms 30_000
  @event [:cyfr, :emissary, :request]
  @attach_id "prism-metrics-aggregator"

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Latency percentiles + counts over the last `seconds` seconds.

  Returns `%{count, error_count, p50, p95, p99}`. All durations in ms.
  """
  def latencies(seconds \\ 60) when is_integer(seconds) and seconds > 0 do
    GenServer.call(__MODULE__, {:latencies, seconds * 1000})
  end

  @doc """
  Error counts in `count` buckets of `bucket_seconds` each, oldest first.
  """
  def error_buckets(count \\ 60, bucket_seconds \\ 60)
      when is_integer(count) and count > 0 and is_integer(bucket_seconds) and bucket_seconds > 0 do
    GenServer.call(__MODULE__, {:error_buckets, count, bucket_seconds})
  end

  # ============================================================================
  # Telemetry handler — runs in the emitting process; cast to avoid blocking.
  # ============================================================================

  @doc false
  def handle_telemetry(@event, measurements, metadata, _config) do
    sample = {
      System.system_time(:millisecond),
      metadata[:tool],
      metadata[:action],
      metadata[:status],
      measurements[:duration_ms] || measurements[:duration]
    }

    GenServer.cast(__MODULE__, {:sample, sample})
  rescue
    # Never let an aggregator hiccup detach the telemetry handler permanently.
    _ -> :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    :telemetry.attach(@attach_id, @event, &__MODULE__.handle_telemetry/4, nil)
    schedule_prune()
    {:ok, %{samples: :queue.new(), size: 0}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@attach_id)
    :ok
  end

  @impl true
  def handle_cast({:sample, sample}, state) do
    {:noreply, %{state | samples: :queue.in(sample, state.samples), size: state.size + 1}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.system_time(:millisecond) - @window_ms
    {samples, dropped} = drop_older_than(state.samples, cutoff, 0)
    schedule_prune()
    {:noreply, %{state | samples: samples, size: state.size - dropped}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:latencies, ms}, _from, state) do
    cutoff = System.system_time(:millisecond) - ms
    list = :queue.to_list(state.samples)

    durations =
      for {ts, _t, _a, _s, d} <- list, ts >= cutoff and is_number(d), do: d

    error_count =
      Enum.count(list, fn {ts, _t, _a, s, _d} ->
        ts >= cutoff and error_status?(s)
      end)

    sorted = Enum.sort(durations)

    {:reply,
     %{
       count: length(durations),
       error_count: error_count,
       p50: percentile(sorted, 0.5),
       p95: percentile(sorted, 0.95),
       p99: percentile(sorted, 0.99)
     }, state}
  end

  def handle_call({:error_buckets, count, bucket_seconds}, _from, state) do
    bucket_ms = bucket_seconds * 1000
    now = System.system_time(:millisecond)
    cutoff = now - count * bucket_ms

    state.samples
    |> :queue.to_list()
    |> Enum.reduce(:array.new(count, default: 0), fn {ts, _t, _a, s, _d}, acc ->
      if ts >= cutoff and error_status?(s) do
        idx = min(div(ts - cutoff, bucket_ms), count - 1)
        :array.set(idx, :array.get(idx, acc) + 1, acc)
      else
        acc
      end
    end)
    |> :array.to_list()
    |> then(&{:reply, &1, state})
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)

  defp drop_older_than(queue, cutoff, dropped) do
    case :queue.peek(queue) do
      :empty ->
        {queue, dropped}

      {:value, {ts, _, _, _, _}} when ts < cutoff ->
        {_, rest} = :queue.out(queue)
        drop_older_than(rest, cutoff, dropped + 1)

      _ ->
        {queue, dropped}
    end
  end

  defp percentile([], _p), do: 0

  defp percentile(sorted, p) do
    n = length(sorted)
    idx = max(0, min(n - 1, trunc(p * (n - 1))))
    Enum.at(sorted, idx)
  end

  defp error_status?(s), do: s in [:error, "error", :failed, "failed"]
end