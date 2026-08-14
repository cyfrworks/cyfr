# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.CeilingTest do
  use ExUnit.Case, async: false

  alias Sanctum.Limits
  alias Sanctum.Policy.Ceiling

  # A partial Limits for clamp tests — clamp only reads the fields the
  # ceiling names, so unset fields may stay nil.
  defp limits(fields), do: struct(Limits, fields)

  setup do
    # Save original config for cleanup
    original_platform = Application.get_env(:cyfr, :platform_ceiling)

    on_exit(fn ->
      if original_platform,
        do: Application.put_env(:cyfr, :platform_ceiling, original_platform),
        else: Application.delete_env(:cyfr, :platform_ceiling)
    end)

    :ok
  end

  # ============================================================================
  # platform_ceiling/0
  # ============================================================================

  describe "platform_ceiling/0" do
    test "returns default ceiling values" do
      Application.delete_env(:cyfr, :platform_ceiling)

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
      assert ceiling.max_request_size == 10 * 1024 * 1024
      assert ceiling.max_response_size == 50 * 1024 * 1024
      assert ceiling.rate_limit_requests == 10_000
      assert ceiling.max_concurrent_tasks == 50
      assert ceiling.batch_timeout == "30m"
    end

    test "config may lower a field" do
      Application.put_env(:cyfr, :platform_ceiling, %{timeout: "5m", max_concurrent_tasks: 10})

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.timeout == "5m"
      assert ceiling.max_concurrent_tasks == 10
      # Other fields keep defaults
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
      assert ceiling.rate_limit_requests == 10_000
    end

    # The compiled number is the absolute maximum. Config that tries to raise
    # it is ignored rather than honoured — otherwise the "infrastructure
    # protection" ceiling is only ever as high as the last operator typo.
    test "config cannot raise a field above the compiled maximum" do
      Application.put_env(:cyfr, :platform_ceiling, %{
        timeout: "1h",
        batch_timeout: "90m",
        max_memory_bytes: 512 * 1024 * 1024,
        max_concurrent_tasks: 100,
        rate_limit_requests: 1_000_000
      })

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.timeout == "30m"
      assert ceiling.batch_timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
      assert ceiling.max_concurrent_tasks == 50
      assert ceiling.rate_limit_requests == 10_000
    end

    test "partial override only affects specified fields" do
      Application.put_env(:cyfr, :platform_ceiling, %{max_memory_bytes: 128 * 1024 * 1024})

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.max_memory_bytes == 128 * 1024 * 1024
      assert ceiling.timeout == "30m"
    end

    test "a malformed or unknown override never widens the ceiling" do
      Application.put_env(:cyfr, :platform_ceiling, %{
        timeout: "not-a-duration",
        max_memory_bytes: "lots",
        nonsense_field: 1
      })

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
      refute Map.has_key?(ceiling, :nonsense_field)
    end
  end

  # ============================================================================
  # clamp/2
  # ============================================================================

  describe "clamp/2" do
    test "clamps numeric fields to ceiling" do
      limits =
        limits(
          max_memory_bytes: 512 * 1024 * 1024,
          max_request_size: 20 * 1024 * 1024,
          max_response_size: 100 * 1024 * 1024,
          max_concurrent_tasks: 100
        )

      ceiling = %{
        max_memory_bytes: 256 * 1024 * 1024,
        max_request_size: 10 * 1024 * 1024,
        max_response_size: 50 * 1024 * 1024,
        max_concurrent_tasks: 50
      }

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.max_memory_bytes == 256 * 1024 * 1024
      assert clamped.max_request_size == 10 * 1024 * 1024
      assert clamped.max_response_size == 50 * 1024 * 1024
      assert clamped.max_concurrent_tasks == 50
    end

    test "clamps duration fields to ceiling" do
      limits = limits(timeout: "2h", batch_timeout: "1h")
      ceiling = %{timeout: "30m", batch_timeout: "30m"}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.timeout == "30m"
      assert clamped.batch_timeout == "30m"
    end

    test "clamps rate_limit.requests" do
      limits = limits(rate_limit: %{requests: 50_000, window: "1m"})
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.rate_limit.requests == 10_000
      assert clamped.rate_limit.window == "1m"
    end

    test "no-op when within ceiling" do
      limits =
        limits(
          timeout: "5m",
          max_memory_bytes: 64 * 1024 * 1024,
          max_concurrent_tasks: 10
        )

      ceiling = %{
        timeout: "30m",
        max_memory_bytes: 256 * 1024 * 1024,
        max_concurrent_tasks: 50
      }

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.timeout == "5m"
      assert clamped.max_memory_bytes == 64 * 1024 * 1024
      assert clamped.max_concurrent_tasks == 10
    end

    test "no-op for fields not in ceiling" do
      limits = limits(max_memory_bytes: 512 * 1024 * 1024)
      ceiling = %{timeout: "30m"}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.max_memory_bytes == 512 * 1024 * 1024
    end

    test "handles nil rate_limit" do
      limits = limits(rate_limit: nil)
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.rate_limit == nil
    end
  end

  # ============================================================================
  # validate/2
  # ============================================================================

  describe "validate/2" do
    test "accepts policy within ceiling" do
      policy_map = %{timeout: "5m", max_memory_bytes: 64 * 1024 * 1024}
      ceiling = %{timeout: "30m", max_memory_bytes: 256 * 1024 * 1024}

      assert :ok = Ceiling.validate(policy_map, ceiling)
    end

    test "rejects policy exceeding numeric ceiling" do
      policy_map = %{max_memory_bytes: 999_999_999_999}
      ceiling = %{max_memory_bytes: 256 * 1024 * 1024}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
      assert msg =~ "max_memory_bytes"
    end

    test "rejects policy exceeding duration ceiling" do
      policy_map = %{timeout: "999h"}
      ceiling = %{timeout: "30m"}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
      assert msg =~ "timeout"
    end

    test "accepts when field not in ceiling" do
      policy_map = %{max_memory_bytes: 999_999_999_999}
      ceiling = %{timeout: "30m"}

      assert :ok = Ceiling.validate(policy_map, ceiling)
    end

    test "duration comparison: 30s < 1m ceiling is ok" do
      policy_map = %{timeout: "30s"}
      ceiling = %{timeout: "1m"}

      assert :ok = Ceiling.validate(policy_map, ceiling)
    end

    test "duration comparison: 2h > 30m ceiling is error" do
      policy_map = %{timeout: "2h"}
      ceiling = %{timeout: "30m"}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
    end

    test "rejects rate_limit.requests exceeding ceiling" do
      policy_map = %{rate_limit: %{requests: 50_000, window: "1m"}}
      ceiling = %{rate_limit_requests: 10_000}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
      assert msg =~ "rate_limit"
    end

    test "accepts rate_limit.requests within ceiling" do
      policy_map = %{rate_limit: %{requests: 100, window: "1m"}}
      ceiling = %{rate_limit_requests: 10_000}

      assert :ok = Ceiling.validate(policy_map, ceiling)
    end

    test "handles string-keyed policy maps" do
      policy_map = %{"timeout" => "999h"}
      ceiling = %{timeout: "30m"}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
    end

    test "handles string-keyed numeric fields" do
      policy_map = %{"max_memory_bytes" => 999_999_999_999}
      ceiling = %{max_memory_bytes: 256 * 1024 * 1024}

      assert {:error, msg} = Ceiling.validate(policy_map, ceiling)
      assert msg =~ "exceeds"
    end
  end

  # ============================================================================
  # effective_ceiling/1
  # ============================================================================

  describe "effective_ceiling/1" do
    test "returns the platform ceiling" do
      Application.delete_env(:cyfr, :platform_ceiling)

      ctx = Sanctum.TestContext.local()
      ceiling = Ceiling.effective_ceiling(ctx)

      assert ceiling.timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
    end

    test "reflects platform ceiling config overrides" do
      Application.put_env(:cyfr, :platform_ceiling, %{max_concurrent_tasks: 10})

      ctx = Sanctum.TestContext.local()
      ceiling = Ceiling.effective_ceiling(ctx)

      assert ceiling.max_concurrent_tasks == 10
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
    end
  end
end
