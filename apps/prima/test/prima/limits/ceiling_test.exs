# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Limits.CeilingTest do
  use ExUnit.Case, async: true

  alias Prima.Limits
  alias Prima.Limits.Ceiling

  # A partial Limits for clamp tests — clamp only reads the fields the
  # ceiling names, so unset fields may stay nil.
  defp limits(fields), do: struct(Limits, fields)

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

    test "a float ceiling clamps instead of raising" do
      # A float ceiling (an operator override such as
      # `%{rate_limit_requests: 5_000.0}`) bounds the whole requests below it.
      limits = limits(rate_limit: %{requests: 50_000, window: "1m"})

      clamped = Ceiling.clamp(limits, %{rate_limit_requests: 5_000.0})

      assert clamped.rate_limit == %{requests: 5_000, window: "1m"}
    end

    test "clamps rate_limit.requests" do
      limits = limits(rate_limit: %{requests: 50_000, window: "1m"})
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.rate_limit.requests == 10_000
      assert clamped.rate_limit.window == "1m"
    end

    test "a shrunken window cannot multiply the rate past the ceiling" do
      # Rate limits must account for the window duration as well as the request count.
      limits = limits(rate_limit: %{requests: 10_000, window: "1s"})
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      # One second holds a sixtieth of the per-minute ceiling.
      assert clamped.rate_limit.requests == div(10_000, 60)
      assert clamped.rate_limit.window == "1s"
    end

    test "a window too small for one request falls back to the ceiling itself" do
      limits = limits(rate_limit: %{requests: 10_000, window: "1ms"})
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.rate_limit == %{requests: 10_000, window: "1m"}
    end

    test "a long window keeps the burst count cap" do
      # The rate over an hour would fit, but the ceiling also bounds the
      # burst a single window may hold.
      limits = limits(rate_limit: %{requests: 500_000, window: "1h"})
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(limits, ceiling)
      assert clamped.rate_limit.requests == 10_000
      assert clamped.rate_limit.window == "1h"
    end

    test "a sub-minute rate within the ceiling is untouched" do
      limits = limits(rate_limit: %{requests: 100, window: "1s"})
      ceiling = %{rate_limit_requests: 10_000}

      assert Ceiling.clamp(limits, ceiling).rate_limit == %{requests: 100, window: "1s"}
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
end
