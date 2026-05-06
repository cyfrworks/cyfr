defmodule Sanctum.Policy.Ceiling do
  @moduledoc """
  Tiered policy ceilings for CYFR.

  Enforces cascading resource limits:
    Platform (absolute max) → Org/Plan tier → Resolved policy

  Core mode: platform ceiling only.
  Arx mode: platform → plan cascade (when :plan_ceilings configured).
  """

  require Logger

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

  @org_plan_cache_ttl :timer.minutes(5)

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
  Returns the plan ceiling for a given plan string.

  Plan ceilings come entirely from `:cyfr, :plan_ceilings` config.
  Returns empty map if no config or unknown plan.
  """
  @spec plan_ceiling(String.t()) :: map()
  def plan_ceiling(plan) when is_binary(plan) do
    Application.get_env(:cyfr, :plan_ceilings, %{})[plan] || %{}
  end

  @doc """
  Returns the effective ceiling for a context.

  Core mode: platform ceiling only.
  Arx mode: platform → plan cascade (only when :plan_ceilings configured).
  """
  @spec effective_ceiling(Sanctum.Context.t()) :: map()
  def effective_ceiling(%Sanctum.Context{} = ctx) do
    platform = platform_ceiling()

    if arx_mode?() do
      plan_ceilings = Application.get_env(:cyfr, :plan_ceilings, %{})

      if plan_ceilings == %{} do
        platform
      else
        plan = get_org_plan(ctx.org_id)
        merge_ceilings(platform, plan_ceiling(plan))
      end
    else
      platform
    end
  end

  @doc """
  Clamp a %Policy{} struct to respect ceiling limits.

  Returns a new %Policy{} with clamped values. Allow-list fields
  (allowed_domains, allowed_tools, etc.) are never clamped.
  """
  @spec clamp(Policy.t(), map()) :: Policy.t()
  def clamp(%Policy{} = policy, ceiling) when is_map(ceiling) do
    policy
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

  @doc """
  Merge two ceiling maps, taking the more restrictive value per field.

  Composable for future project-level layer.
  """
  @spec merge_ceilings(map(), map()) :: map()
  def merge_ceilings(ceil_a, ceil_b) when is_map(ceil_a) and is_map(ceil_b) do
    all_keys = MapSet.union(MapSet.new(Map.keys(ceil_a)), MapSet.new(Map.keys(ceil_b)))

    Enum.reduce(all_keys, %{}, fn key, acc ->
      case {Map.get(ceil_a, key), Map.get(ceil_b, key)} do
        {nil, val} -> Map.put(acc, key, val)
        {val, nil} -> Map.put(acc, key, val)
        {a, b} -> Map.put(acc, key, more_restrictive(key, a, b))
      end
    end)
  end

  # ============================================================================
  # Private: Comparison helpers
  # ============================================================================

  defp more_restrictive(key, a, b) when key in @duration_fields do
    with {:ok, a_ms} <- Policy.parse_duration(a),
         {:ok, b_ms} <- Policy.parse_duration(b) do
      if a_ms <= b_ms, do: a, else: b
    else
      _ -> a
    end
  end

  defp more_restrictive(_key, a, b) when is_number(a) and is_number(b), do: min(a, b)
  defp more_restrictive(_key, a, _b), do: a

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

  # ============================================================================
  # Private: Org plan lookup (Arx mode only)
  # ============================================================================

  defp get_org_plan(nil), do: "free"

  defp get_org_plan(org_id) do
    case Arca.Cache.get({:org_plan, org_id}) do
      {:ok, plan} ->
        plan

      :miss ->
        plan = fetch_org_plan(org_id)
        Arca.Cache.put({:org_plan, org_id}, plan, @org_plan_cache_ttl)
        plan
    end
  end

  defp fetch_org_plan(org_id) do
    Application.fetch_env!(:cyfr, :plan_resolver).get_plan(org_id)
  end

  defp arx_mode?, do: Sanctum.Edition.arx?()
end
