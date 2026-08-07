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

  alias Sanctum.Policy

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

  Config overrides individual fields via `:cyfr, :platform_ceiling`.
  """
  @spec platform_ceiling() :: map()
  def platform_ceiling do
    overrides = Application.get_env(:cyfr, :platform_ceiling, %{})
    Map.merge(@platform_ceiling, overrides)
  end

  @doc """
  Returns the effective ceiling for a context — the platform ceiling.
  """
  @spec effective_ceiling(Sanctum.Context.t()) :: map()
  def effective_ceiling(%Sanctum.Context{} = _ctx), do: platform_ceiling()

  @doc """
  The clamped field names, as spelled on the clamped structs.

  `Sanctum.Limits` locks its field set to this list by test. Note the
  asymmetry: the struct field is `:rate_limit` while the ceiling map keys
  its bound as `:rate_limit_requests` (only the request count is clamped).
  """
  @spec clamped_fields() :: [atom()]
  def clamped_fields, do: @numeric_fields ++ @duration_fields ++ [:rate_limit]

  @doc """
  Clamp a %Policy{} or %Sanctum.Limits{} struct to respect ceiling limits.

  Returns a new struct of the same type with clamped values. Allow-list
  fields (allowed_domains, allowed_tools, etc.) are never clamped.
  """
  @spec clamp(Policy.t() | Sanctum.Limits.t(), map()) :: Policy.t() | Sanctum.Limits.t()
  def clamp(%Policy{} = policy, ceiling) when is_map(ceiling) do
    policy
    |> clamp_numeric_fields(ceiling)
    |> clamp_duration_fields(ceiling)
    |> clamp_rate_limit(ceiling)
  end

  def clamp(%Sanctum.Limits{} = limits, ceiling) when is_map(ceiling) do
    limits
    |> clamp_numeric_fields(ceiling)
    |> clamp_duration_fields(ceiling)
    |> clamp_rate_limit(ceiling)
  end

  @doc """
  Validate a policy map against ceiling limits (pre-save).

  Returns `:ok` or `{:error, "descriptive message"}`.
  Handles both atom-keyed and string-keyed policy maps.
  """
  @spec validate(map(), map()) :: :ok | {:error, String.t()}
  def validate(policy_map, ceiling) when is_map(policy_map) and is_map(ceiling) do
    errors =
      validate_numeric_fields(policy_map, ceiling) ++
        validate_duration_fields(policy_map, ceiling) ++
        validate_rate_limit_field(policy_map, ceiling)

    case errors do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  # ============================================================================
  # Private: Clamping
  # ============================================================================

  defp clamp_numeric_fields(policy, ceiling) do
    Enum.reduce(@numeric_fields, policy, fn field, acc ->
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

  defp clamp_duration_fields(policy, ceiling) do
    Enum.reduce(@duration_fields, policy, fn field, acc ->
      case Map.get(ceiling, field) do
        nil ->
          acc

        max_dur ->
          current = Map.get(acc, field)

          with {:ok, current_ms} <- Policy.parse_duration(current),
               {:ok, max_ms} <- Policy.parse_duration(max_dur) do
            if current_ms > max_ms do
              Map.put(acc, field, max_dur)
            else
              acc
            end
          else
            _ -> acc
          end
      end
    end)
  end

  defp clamp_rate_limit(policy, ceiling) do
    case {policy.rate_limit, Map.get(ceiling, :rate_limit_requests)} do
      {%{requests: req} = rl, max_req} when is_number(max_req) and req > max_req ->
        %{policy | rate_limit: %{rl | requests: max_req}}

      _ ->
        policy
    end
  end

  # ============================================================================
  # Private: Validation
  # ============================================================================

  defp validate_numeric_fields(policy_map, ceiling) do
    Enum.flat_map(@numeric_fields, fn field ->
      val = get_field(policy_map, field)
      max = Map.get(ceiling, field)

      case {val, max} do
        {v, m} when is_number(v) and is_number(m) and v > m ->
          ["Policy value for #{field} (#{v}) exceeds maximum (#{m})"]

        _ ->
          []
      end
    end)
  end

  defp validate_duration_fields(policy_map, ceiling) do
    Enum.flat_map(@duration_fields, fn field ->
      val = get_field(policy_map, field)
      max = Map.get(ceiling, field)

      case {val, max} do
        {v, m} when is_binary(v) and is_binary(m) ->
          with {:ok, val_ms} <- Policy.parse_duration(v),
               {:ok, max_ms} <- Policy.parse_duration(m) do
            if val_ms > max_ms do
              ["Policy value for #{field} (#{v}) exceeds maximum (#{m})"]
            else
              []
            end
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp validate_rate_limit_field(policy_map, ceiling) do
    rl = get_field(policy_map, :rate_limit)
    max = Map.get(ceiling, :rate_limit_requests)

    case {rl, max} do
      {%{requests: req}, m} when is_number(req) and is_number(m) and req > m ->
        ["Policy value for rate_limit.requests (#{req}) exceeds maximum (#{m})"]

      _ ->
        []
    end
  end

  # Read a field from a policy map, handling both atom and string keys.
  defp get_field(policy_map, field) when is_atom(field) do
    case Map.get(policy_map, field) do
      nil -> Map.get(policy_map, Atom.to_string(field))
      val -> val
    end
  end
end
