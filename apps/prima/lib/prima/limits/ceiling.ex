# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Limits.Ceiling do
  @moduledoc """
  The platform ceiling: the hard upper bound a resolved policy is clamped
  to, regardless of tenant. The compiled values are the highest this
  software ever hands out; `lowered/1` applies an operator's overrides, which
  may lower a field and never raise it, and `clamp/2` bounds a
  `Prima.Limits` struct by a ceiling. Reading the configured overrides is the
  caller's (`Sanctum.Policy.Ceiling.platform_ceiling/0`).
  """

  @numeric_fields [
    :max_memory_bytes,
    :max_request_size,
    :max_response_size,
    :max_concurrent_tasks
  ]
  @duration_fields [:timeout, :batch_timeout]

  @hard %{
    timeout: "30m",
    max_memory_bytes: 256 * 1024 * 1024,
    max_request_size: 10 * 1024 * 1024,
    max_response_size: 50 * 1024 * 1024,
    rate_limit_requests: 10_000,
    max_concurrent_tasks: 50,
    batch_timeout: "30m"
  }

  @doc """
  The ceiling with `overrides` applied: a field an override names takes the
  override only when it is lower than the compiled value; a field the
  compiled ceiling does not know, or a value that does not compare, is
  ignored.
  """
  @spec lowered(map() | keyword()) :: map()
  def lowered(overrides) do
    Enum.reduce(overrides, @hard, fn {field, value}, acc ->
      case Map.fetch(acc, field) do
        {:ok, hard_max} -> Map.put(acc, field, lower_of(field, value, hard_max))
        :error -> acc
      end
    end)
  end

  defp lower_of(field, value, hard_max) when field in @duration_fields do
    with {:ok, value_ms} <- Prima.Limits.parse_duration(value),
         {:ok, max_ms} <- Prima.Limits.parse_duration(hard_max) do
      if value_ms < max_ms, do: value, else: hard_max
    else
      _ -> hard_max
    end
  end

  defp lower_of(_field, value, hard_max) when is_number(value) and is_number(hard_max),
    do: min(value, hard_max)

  defp lower_of(_field, _value, hard_max), do: hard_max

  @doc """
  The clamped field names, as spelled on the clamped structs.

  `Prima.Limits` locks its field set to this list by test. The struct field
  is `:rate_limit` while the ceiling map keys its bound as
  `:rate_limit_requests` — a per-minute rate and burst count in one number.
  """
  @spec clamped_fields() :: [atom()]
  def clamped_fields, do: @numeric_fields ++ @duration_fields ++ [:rate_limit]

  @doc """
  Clamp a `Prima.Limits` struct to a ceiling map. Resource allowlists are
  never clamped — they live on consent edges, not here.
  """
  @spec clamp(Prima.Limits.t(), map()) :: Prima.Limits.t()
  def clamp(%Prima.Limits{} = limits, ceiling) when is_map(ceiling) do
    limits
    |> clamp_numeric_fields(ceiling)
    |> clamp_duration_fields(ceiling)
    |> clamp_rate_limit(ceiling)
  end

  defp clamp_numeric_fields(limits, ceiling) do
    Enum.reduce(@numeric_fields, limits, fn field, acc ->
      case Map.get(ceiling, field) do
        nil ->
          acc

        max_val ->
          current = Map.get(acc, field)
          if is_number(current) and current > max_val, do: Map.put(acc, field, max_val), else: acc
      end
    end)
  end

  defp clamp_duration_fields(limits, ceiling) do
    Enum.reduce(@duration_fields, limits, fn field, acc ->
      case Map.get(ceiling, field) do
        nil ->
          acc

        max_dur ->
          with {:ok, current_ms} <- Prima.Limits.parse_duration(Map.get(acc, field)),
               {:ok, max_ms} <- Prima.Limits.parse_duration(max_dur) do
            if current_ms > max_ms, do: Map.put(acc, field, max_dur), else: acc
          else
            # A duration the parser rejects is clamped, never passed through.
            _ -> Map.put(acc, field, max_dur)
          end
      end
    end)
  end

  # Both the burst count and the per-minute rate are bounded: the count is
  # scaled for a sub-minute window and kept for a longer one; an invalid
  # window, or a rate too small for one request in it, takes the ceiling at
  # one minute. A float ceiling means the whole requests below it.
  defp clamp_rate_limit(limits, ceiling) do
    with %{requests: req, window: window} = rl <- limits.rate_limit,
         max_req when is_number(max_req) <- Map.get(ceiling, :rate_limit_requests) do
      max_req = trunc(max_req)

      case Prima.Limits.parse_duration(window) do
        {:ok, window_ms} when window_ms > 0 ->
          max_for_window = min(max_req, div(max_req * window_ms, 60_000))

          cond do
            req <= max_for_window -> limits
            max_for_window >= 1 -> %{limits | rate_limit: %{rl | requests: max_for_window}}
            true -> %{limits | rate_limit: %{requests: max_req, window: "1m"}}
          end

        _ ->
          %{limits | rate_limit: %{requests: max_req, window: "1m"}}
      end
    else
      _ -> limits
    end
  end
end
