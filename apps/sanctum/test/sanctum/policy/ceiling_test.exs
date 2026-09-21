# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.CeilingTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy.Ceiling

  setup do
    # Save original config for cleanup
    original_platform = Application.get_env(:sanctum, :platform_ceiling)

    on_exit(fn ->
      if original_platform,
        do: Application.put_env(:sanctum, :platform_ceiling, original_platform),
        else: Application.delete_env(:sanctum, :platform_ceiling)
    end)

    :ok
  end

  # ============================================================================
  # platform_ceiling/0
  # ============================================================================

  describe "platform_ceiling/0" do
    test "returns default ceiling values" do
      Application.delete_env(:sanctum, :platform_ceiling)

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
      Application.put_env(:sanctum, :platform_ceiling, %{timeout: "5m", max_concurrent_tasks: 10})

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
      Application.put_env(:sanctum, :platform_ceiling, %{
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
      Application.put_env(:sanctum, :platform_ceiling, %{max_memory_bytes: 128 * 1024 * 1024})

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.max_memory_bytes == 128 * 1024 * 1024
      assert ceiling.timeout == "30m"
    end

    test "a malformed or unknown override never widens the ceiling" do
      Application.put_env(:sanctum, :platform_ceiling, %{
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
end
