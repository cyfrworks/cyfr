defmodule Sanctum.Policy.CeilingTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy
  alias Sanctum.Policy.Ceiling

  setup do
    # Save original config for cleanup
    original_platform = Application.get_env(:cyfr, :platform_ceiling)
    original_plans = Application.get_env(:cyfr, :plan_ceilings)
    original_edition = Application.get_env(:cyfr, :edition)

    on_exit(fn ->
      if original_platform,
        do: Application.put_env(:cyfr, :platform_ceiling, original_platform),
        else: Application.delete_env(:cyfr, :platform_ceiling)

      if original_plans,
        do: Application.put_env(:cyfr, :plan_ceilings, original_plans),
        else: Application.delete_env(:cyfr, :plan_ceilings)

      if original_edition,
        do: Application.put_env(:cyfr, :edition, original_edition),
        else: Application.delete_env(:cyfr, :edition)
    end)

    # Ensure Arca.Cache is initialized for effective_ceiling tests
    Arca.Cache.init()

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

    test "config override merges with defaults" do
      Application.put_env(:cyfr, :platform_ceiling, %{timeout: "1h", max_concurrent_tasks: 100})

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.timeout == "1h"
      assert ceiling.max_concurrent_tasks == 100
      # Other fields keep defaults
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
      assert ceiling.rate_limit_requests == 10_000
    end

    test "partial override only affects specified fields" do
      Application.put_env(:cyfr, :platform_ceiling, %{max_memory_bytes: 512 * 1024 * 1024})

      ceiling = Ceiling.platform_ceiling()
      assert ceiling.max_memory_bytes == 512 * 1024 * 1024
      assert ceiling.timeout == "30m"
    end
  end

  # ============================================================================
  # plan_ceiling/1
  # ============================================================================

  describe "plan_ceiling/1" do
    test "returns configured plan ceiling" do
      Application.put_env(:cyfr, :plan_ceilings, %{
        "free" => %{max_memory_bytes: 64 * 1024 * 1024, timeout: "5m"}
      })

      result = Ceiling.plan_ceiling("free")
      assert result.max_memory_bytes == 64 * 1024 * 1024
      assert result.timeout == "5m"
    end

    test "returns empty map for unknown plan" do
      Application.put_env(:cyfr, :plan_ceilings, %{
        "free" => %{max_memory_bytes: 64 * 1024 * 1024}
      })

      assert %{} = Ceiling.plan_ceiling("enterprise")
    end

    test "returns empty map when no config" do
      Application.delete_env(:cyfr, :plan_ceilings)
      assert %{} = Ceiling.plan_ceiling("free")
    end
  end

  # ============================================================================
  # clamp/2
  # ============================================================================

  describe "clamp/2" do
    test "clamps numeric fields to ceiling" do
      policy = %Policy{
        max_memory_bytes: 512 * 1024 * 1024,
        max_request_size: 20 * 1024 * 1024,
        max_response_size: 100 * 1024 * 1024,
        max_concurrent_tasks: 100
      }

      ceiling = %{
        max_memory_bytes: 256 * 1024 * 1024,
        max_request_size: 10 * 1024 * 1024,
        max_response_size: 50 * 1024 * 1024,
        max_concurrent_tasks: 50
      }

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.max_memory_bytes == 256 * 1024 * 1024
      assert clamped.max_request_size == 10 * 1024 * 1024
      assert clamped.max_response_size == 50 * 1024 * 1024
      assert clamped.max_concurrent_tasks == 50
    end

    test "clamps duration fields to ceiling" do
      policy = %Policy{timeout: "2h", batch_timeout: "1h"}
      ceiling = %{timeout: "30m", batch_timeout: "30m"}

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.timeout == "30m"
      assert clamped.batch_timeout == "30m"
    end

    test "clamps rate_limit.requests" do
      policy = %Policy{rate_limit: %{requests: 50_000, window: "1m"}}
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.rate_limit.requests == 10_000
      assert clamped.rate_limit.window == "1m"
    end

    test "no-op when within ceiling" do
      policy = %Policy{
        timeout: "5m",
        max_memory_bytes: 64 * 1024 * 1024,
        max_concurrent_tasks: 10
      }

      ceiling = %{
        timeout: "30m",
        max_memory_bytes: 256 * 1024 * 1024,
        max_concurrent_tasks: 50
      }

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.timeout == "5m"
      assert clamped.max_memory_bytes == 64 * 1024 * 1024
      assert clamped.max_concurrent_tasks == 10
    end

    test "preserves allow-list fields unchanged" do
      policy = %Policy{
        allowed_domains: ["example.com"],
        allowed_tools: ["component.*"],
        allowed_paths: ["data/"],
        timeout: "2h"
      }

      ceiling = %{timeout: "30m"}

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.allowed_domains == ["example.com"]
      assert clamped.allowed_tools == ["component.*"]
      assert clamped.allowed_paths == ["data/"]
    end

    test "no-op for fields not in ceiling" do
      policy = %Policy{max_memory_bytes: 512 * 1024 * 1024}
      ceiling = %{timeout: "30m"}

      clamped = Ceiling.clamp(policy, ceiling)
      assert clamped.max_memory_bytes == 512 * 1024 * 1024
    end

    test "handles nil rate_limit" do
      policy = %Policy{rate_limit: nil}
      ceiling = %{rate_limit_requests: 10_000}

      clamped = Ceiling.clamp(policy, ceiling)
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
  # merge_ceilings/2
  # ============================================================================

  describe "merge_ceilings/2" do
    test "takes more restrictive numeric value" do
      a = %{max_memory_bytes: 256 * 1024 * 1024, max_concurrent_tasks: 50}
      b = %{max_memory_bytes: 128 * 1024 * 1024, max_concurrent_tasks: 100}

      merged = Ceiling.merge_ceilings(a, b)
      assert merged.max_memory_bytes == 128 * 1024 * 1024
      assert merged.max_concurrent_tasks == 50
    end

    test "takes more restrictive duration" do
      a = %{timeout: "30m"}
      b = %{timeout: "5m"}

      merged = Ceiling.merge_ceilings(a, b)
      assert merged.timeout == "5m"
    end

    test "empty map means no restriction" do
      a = %{timeout: "30m", max_memory_bytes: 256 * 1024 * 1024}
      b = %{}

      merged = Ceiling.merge_ceilings(a, b)
      assert merged == a
    end

    test "keeps fields from both maps" do
      a = %{timeout: "30m"}
      b = %{max_memory_bytes: 128 * 1024 * 1024}

      merged = Ceiling.merge_ceilings(a, b)
      assert merged.timeout == "30m"
      assert merged.max_memory_bytes == 128 * 1024 * 1024
    end

    test "duration comparison handles different units" do
      a = %{timeout: "2h"}
      b = %{timeout: "90m"}

      merged = Ceiling.merge_ceilings(a, b)
      assert merged.timeout == "90m"
    end
  end

  # ============================================================================
  # effective_ceiling/1
  # ============================================================================

  describe "effective_ceiling/1" do
    test "Core mode returns platform ceiling only" do
      Application.delete_env(:cyfr, :edition)
      Application.delete_env(:cyfr, :platform_ceiling)

      ctx = Sanctum.Context.local()
      ceiling = Ceiling.effective_ceiling(ctx)

      assert ceiling.timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
    end

    test "Arx mode with plan config merges ceilings" do
      Application.put_env(:cyfr, :edition, :arx)

      Application.put_env(:cyfr, :plan_ceilings, %{
        "free" => %{max_memory_bytes: 64 * 1024 * 1024, timeout: "5m"}
      })

      # Pre-cache the org plan so we don't hit the DB
      Arca.Cache.put({:org_plan, "test_org"}, "free", 60_000)

      ctx = %Sanctum.Context{
        user_id: "test",
        org_id: "test_org",
        scope: :local,
        permissions: MapSet.new(),
        authenticated: true
      }

      ceiling = Ceiling.effective_ceiling(ctx)

      # Plan ceiling is more restrictive, so it wins
      assert ceiling.max_memory_bytes == 64 * 1024 * 1024
      assert ceiling.timeout == "5m"
      # Platform ceiling fields not overridden by plan
      assert ceiling.max_request_size == 10 * 1024 * 1024
    end

    test "Arx mode without plan config returns platform ceiling" do
      Application.put_env(:cyfr, :edition, :arx)
      Application.delete_env(:cyfr, :plan_ceilings)
      Application.delete_env(:cyfr, :platform_ceiling)

      ctx = Sanctum.Context.local()
      ceiling = Ceiling.effective_ceiling(ctx)

      assert ceiling.timeout == "30m"
      assert ceiling.max_memory_bytes == 256 * 1024 * 1024
    end

    test "Arx mode with nil org_id defaults to free plan" do
      Application.put_env(:cyfr, :edition, :arx)

      Application.put_env(:cyfr, :plan_ceilings, %{
        "free" => %{max_concurrent_tasks: 10}
      })

      ctx = %Sanctum.Context{
        user_id: "test",
        org_id: nil,
        scope: :local,
        permissions: MapSet.new(),
        authenticated: true
      }

      ceiling = Ceiling.effective_ceiling(ctx)
      assert ceiling.max_concurrent_tasks == 10
    end
  end
end
