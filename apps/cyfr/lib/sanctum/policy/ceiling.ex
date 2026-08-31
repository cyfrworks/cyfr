# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.Ceiling do
  @moduledoc """
  Policy ceilings for CYFR.

  Enforces an absolute resource limit:
    Platform (absolute max) → Resolved policy

  The platform ceiling is infrastructure protection — the hard upper bound a
  resolved policy is clamped to, regardless of tenant.
  """

  # --- Clamped field categories ---

  @numeric_fields [
    :max_memory_bytes,
    :max_request_size,
    :max_response_size,
    :max_concurrent_tasks
  ]
  @duration_fields [:timeout, :batch_timeout]

  # --- Platform ceiling (absolute max, infrastructure protection) ---

  @platform_ceiling %{
    timeout: "30m",
    max_memory_bytes: 256 * 1024 * 1024,
    max_request_size: 10 * 1024 * 1024,
    max_response_size: 50 * 1024 * 1024,
    rate_limit_requests: 10_000,
    max_concurrent_tasks: 50,
    batch_timeout: "30m"
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the platform ceiling (absolute infrastructure max).

  Config may lower individual fields via `:cyfr, :platform_ceiling`; it may
  not raise them. "Absolute infrastructure max" has to mean the compiled
  number is the highest this instance will ever hand out — a plain merge let
  a config key move the roof up, which is the one thing a ceiling exists to
  prevent. An override that is not lower is ignored.
  """
  @spec platform_ceiling() :: map()
  def platform_ceiling do
    overrides = Application.get_env(:cyfr, :platform_ceiling, %{})

    Enum.reduce(overrides, @platform_ceiling, fn {field, value}, acc ->
      case Map.fetch(acc, field) do
        {:ok, hard_max} -> Map.put(acc, field, lower_of(field, value, hard_max))
        # A field the compiled ceiling does not know is not a ceiling field;
        # ignore it rather than inventing a bound nothing clamps against.
        :error -> acc
      end
    end)
  end

  defp lower_of(field, value, hard_max) when field in @duration_fields do
    with {:ok, value_ms} <- Sanctum.Limits.parse_duration(value),
         {:ok, max_ms} <- Sanctum.Limits.parse_duration(hard_max) do
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

  `Sanctum.Limits` locks its field set to this list by test. Note the
  asymmetry: the struct field is `:rate_limit` while the ceiling map keys
  its bound as `:rate_limit_requests` — a per-minute rate and burst count
  in one number (see `clamp_rate_limit/2`).
  """
  @spec clamped_fields() :: [atom()]
  def clamped_fields, do: @numeric_fields ++ @duration_fields ++ [:rate_limit]

  @doc """
  Clamp a %Sanctum.Limits{} struct to respect ceiling limits.

  Returns a new struct with clamped values. Resource allowlists are never
  clamped — they live on consent edges, not here.
  """
  @spec clamp(Sanctum.Limits.t(), map()) :: Sanctum.Limits.t()
  def clamp(%Sanctum.Limits{} = limits, ceiling) when is_map(ceiling) do
    limits
    |> clamp_numeric_fields(ceiling)
    |> clamp_duration_fields(ceiling)
    |> clamp_rate_limit(ceiling)
  end

  # ============================================================================
  # Private: Clamping
  # ============================================================================

  defp clamp_numeric_fields(limits, ceiling) do
    Enum.reduce(@numeric_fields, limits, fn field, acc ->
      case Map.get(ceiling, field) do
        nil ->
          acc

        max_val ->
          current = Map.get(acc, field)

          if is_number(current) and current > max_val do
            Map.put(acc, field, max_val)
          else
            acc
          end
      end
    end)
  end

  defp clamp_duration_fields(limits, ceiling) do
    Enum.reduce(@duration_fields, limits, fn field, acc ->
      case Map.get(ceiling, field) do
        nil ->
          acc

        max_dur ->
          current = Map.get(acc, field)

          with {:ok, current_ms} <- Sanctum.Limits.parse_duration(current),
               {:ok, max_ms} <- Sanctum.Limits.parse_duration(max_dur) do
            if current_ms > max_ms do
              Map.put(acc, field, max_dur)
            else
              acc
            end
          else
            # Fail closed, matching lower_of/3: a duration the parser
            # rejects must not pass through UNCLAMPED — that would let an
            # unparseable timeout escape the platform ceiling entirely.
            _ -> Map.put(acc, field, max_dur)
          end
      end
    end)
  end

  # The ceiling bounds both the BURST and the RATE. Clamping the count
  # alone let a shrunken window multiply it — `%{requests: 10_000,
  # window: "1ms"}` passed a 10k ceiling as six hundred million a minute —
  # so a sub-minute window also scales the count to hold the per-minute
  # rate; a window longer than a minute keeps the plain count cap (the
  # burst bound the ceiling always meant). The declared window is kept;
  # one too small to hold even a single request under the ceiling, or one
  # the parser refuses, is replaced with the ceiling itself at one
  # minute — fail closed, like the duration clamp above.
  defp clamp_rate_limit(limits, ceiling) do
    with %{requests: req, window: window} = rl <- limits.rate_limit,
         max_req when is_number(max_req) <- Map.get(ceiling, :rate_limit_requests) do
      case Sanctum.Limits.parse_duration(window) do
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
