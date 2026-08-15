# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Limits do
  @moduledoc """
  The resolved numeric limits for one node of a consented execution graph.

  Carries exactly the seven fields `Sanctum.Policy.Ceiling` clamps — and
  nothing else. Instances live inside a resolved policy blob (one per node)
  and are clamped against the platform ceiling once, when an Authority is
  built, never at use time. The field set is locked to
  `Sanctum.Policy.Ceiling.clamped_fields/0` by test so the two cannot drift.

  Durations are strings (`"30s"`, `"5m"`); parse on demand with
  `timeout_ms/1` / `batch_timeout_ms/1` or `parse_duration/1`.

  ## Examples

      iex> {:ok, limits} = Sanctum.Limits.new(%{
      ...>   "timeout" => "30s",
      ...>   "max_memory_bytes" => 67_108_864,
      ...>   "max_request_size" => 1_048_576,
      ...>   "max_response_size" => 5_242_880,
      ...>   "rate_limit" => %{"requests" => 100, "window" => "1m"},
      ...>   "max_concurrent_tasks" => 1,
      ...>   "batch_timeout" => "30s"
      ...> })
      iex> limits.timeout
      "30s"
      iex> limits.rate_limit
      %{requests: 100, window: "1m"}

      iex> Sanctum.Limits.new(%{"timeout" => "30s"})
      {:error, {:invalid_limit, :batch_timeout, "is required"}}

  """

  @type rate_limit :: %{requests: non_neg_integer(), window: String.t()}

  @type t :: %__MODULE__{
          timeout: String.t(),
          max_memory_bytes: non_neg_integer(),
          max_request_size: non_neg_integer(),
          max_response_size: non_neg_integer(),
          rate_limit: rate_limit(),
          max_concurrent_tasks: non_neg_integer(),
          batch_timeout: String.t()
        }

  defstruct [
    :timeout,
    :max_memory_bytes,
    :max_request_size,
    :max_response_size,
    :rate_limit,
    :max_concurrent_tasks,
    :batch_timeout
  ]

  @numeric_fields [
    :max_memory_bytes,
    :max_request_size,
    :max_response_size,
    :max_concurrent_tasks
  ]
  @duration_fields [:timeout, :batch_timeout]
  @fields Enum.sort(@numeric_fields ++ @duration_fields ++ [:rate_limit])

  @doc """
  The seven limit field names, sorted.

  Locked to `Sanctum.Policy.Ceiling.clamped_fields/0` by test.
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  @type_defaults %{
    catalyst: %{
      timeout: "3m",
      max_memory_bytes: 67_108_864,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      rate_limit: %{requests: 100, window: "1m"},
      max_concurrent_tasks: 10,
      batch_timeout: "5m"
    },
    formula: %{
      timeout: "5m",
      max_memory_bytes: 67_108_864,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      rate_limit: %{requests: 100, window: "1m"},
      max_concurrent_tasks: 10,
      batch_timeout: "5m"
    },
    reagent: %{
      timeout: "1m",
      max_memory_bytes: 67_108_864,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      rate_limit: %{requests: 100, window: "1m"},
      max_concurrent_tasks: 10,
      batch_timeout: "5m"
    },
    tincture: %{
      timeout: "1m",
      max_memory_bytes: 67_108_864,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      rate_limit: %{requests: 100, window: "1m"},
      max_concurrent_tasks: 10,
      batch_timeout: "5m"
    }
  }

  @doc """
  The default limits for a component type — the base a manifest's
  `caps.limits` merges over before the operator adjusts and the ceiling
  clamps.

  Deliberately literal (the ZeroAuthority doctrine): these literals are the
  only source, so nothing can silently loosen them — the per-type values
  are pinned by test.
  """
  @spec defaults(atom()) :: t()
  def defaults(component_type) when is_map_key(@type_defaults, component_type) do
    struct(__MODULE__, Map.fetch!(@type_defaults, component_type))
  end

  @doc """
  Build a `%Sanctum.Limits{}` from an atom- or string-keyed map.

  Fail-closed allowlist parsing: every one of the seven fields is required,
  unknown keys are rejected, numerics must be non-negative integers (no
  floats — the canonical digest domain has none), durations must parse via
  `parse_duration/1`, and `rate_limit` must be a map of `requests`
  (non-negative integer) and `window` (duration). A blob that omits a limit
  gets an error, not a default — a fallback here would be a silent widening.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_limit, atom(), String.t()}}
  def new(map) when is_map(map) do
    with {:ok, normalized} <- normalize_keys(map),
         :ok <- require_all_fields(normalized),
         {:ok, validated} <- validate_fields(normalized) do
      {:ok, struct(__MODULE__, validated)}
    end
  end

  def new(other) do
    {:error, {:invalid_limit, :input, "expected a map, got: #{inspect(other)}"}}
  end

  @doc """
  Parsed `timeout` in milliseconds.
  """
  @spec timeout_ms(t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def timeout_ms(%__MODULE__{timeout: timeout}), do: parse_duration(timeout)

  @doc """
  Parsed `batch_timeout` in milliseconds.
  """
  @spec batch_timeout_ms(t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def batch_timeout_ms(%__MODULE__{batch_timeout: bt}), do: parse_duration(bt)

  @doc """
  Parse a duration string to milliseconds.

  Supports: "500ms", "30s", "5m", "1h", or integer seconds.

  ## Examples

      iex> Sanctum.Limits.parse_duration("30s")
      {:ok, 30_000}

      iex> Sanctum.Limits.parse_duration("5m")
      {:ok, 300_000}

  """
  @spec parse_duration(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_duration(duration) when is_binary(duration) do
    cond do
      String.ends_with?(duration, "ms") ->
        parse_int_unit(duration, "ms", 1)

      String.ends_with?(duration, "s") ->
        parse_int_unit(duration, "s", 1000)

      String.ends_with?(duration, "m") ->
        parse_int_unit(duration, "m", 60 * 1000)

      String.ends_with?(duration, "h") ->
        parse_int_unit(duration, "h", 60 * 60 * 1000)

      true ->
        case Integer.parse(duration) do
          {n, ""} ->
            {:ok, n * 1000}

          _ ->
            {:error,
             "Invalid duration '#{duration}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
        end
    end
  end

  def parse_duration(other) do
    {:error,
     "Invalid duration #{inspect(other)}. Expected a string like '30s', '5m', '1h', or '500ms'"}
  end

  defp parse_int_unit(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} ->
        {:ok, n * multiplier}

      _ ->
        {:error,
         "Invalid duration '#{str}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
    end
  end

  @doc """
  Clamp against a ceiling map. Delegates to `Sanctum.Policy.Ceiling.clamp/2`
  so there is exactly one clamping implementation.
  """
  @spec clamp(t(), map()) :: t()
  def clamp(%__MODULE__{} = limits, ceiling) when is_map(ceiling) do
    Sanctum.Policy.Ceiling.clamp(limits, ceiling)
  end

  # ============================================================================
  # Private: parsing
  # ============================================================================

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, field} ->
          if Map.has_key?(acc, field) do
            {:halt, {:error, {:invalid_limit, field, "duplicate key"}}}
          else
            {:cont, {:ok, Map.put(acc, field, value)}}
          end

        :unknown ->
          {:halt, {:error, {:invalid_limit, :unknown_field, inspect(key)}}}
      end
    end)
  end

  for field <- @fields do
    defp normalize_key(unquote(field)), do: {:ok, unquote(field)}
    defp normalize_key(unquote(Atom.to_string(field))), do: {:ok, unquote(field)}
  end

  defp normalize_key(_), do: :unknown

  defp require_all_fields(normalized) do
    case Enum.find(@fields, &(not Map.has_key?(normalized, &1))) do
      nil -> :ok
      missing -> {:error, {:invalid_limit, missing, "is required"}}
    end
  end

  defp validate_fields(normalized) do
    Enum.reduce_while(normalized, {:ok, %{}}, fn {field, value}, {:ok, acc} ->
      case validate_field(field, value) do
        {:ok, validated} -> {:cont, {:ok, Map.put(acc, field, validated)}}
        {:error, reason} -> {:halt, {:error, {:invalid_limit, field, reason}}}
      end
    end)
  end

  defp validate_field(field, value) when field in @numeric_fields do
    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, "must be a non-negative integer, got: #{inspect(value)}"}
    end
  end

  defp validate_field(field, value) when field in @duration_fields do
    # Non-negative, matching the numeric fields: parse_duration accepts a
    # leading minus ("-1s" → -1000ms), and a negative deadline downstream
    # is a timeout that already fired or never does.
    with true <- is_binary(value),
         {:ok, ms} when ms >= 0 <- parse_duration(value) do
      {:ok, value}
    else
      _ -> {:error, "must be a non-negative duration string like \"30s\", got: #{inspect(value)}"}
    end
  end

  defp validate_field(:rate_limit, value) when is_map(value) do
    requests = Map.get(value, :requests, Map.get(value, "requests"))
    window = Map.get(value, :window, Map.get(value, "window"))

    cond do
      map_size(value) != 2 ->
        {:error, "must have exactly requests and window, got: #{inspect(value)}"}

      not (is_integer(requests) and requests >= 0) ->
        {:error, "requests must be a non-negative integer, got: #{inspect(requests)}"}

      not (is_binary(window) and match?({:ok, _}, parse_duration(window))) ->
        {:error, "window must be a duration string, got: #{inspect(window)}"}

      true ->
        {:ok, %{requests: requests, window: window}}
    end
  end

  defp validate_field(:rate_limit, value) do
    {:error, "must be a map of requests and window, got: #{inspect(value)}"}
  end
end
