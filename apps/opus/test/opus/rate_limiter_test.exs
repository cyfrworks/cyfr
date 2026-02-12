defmodule Opus.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Opus.RateLimiter

  setup do
    Arca.Cache.init()

    # Start rate limiter manually since it's no longer in the supervision tree
    # (rate limiting is enforced via Sanctum.MCP, not the local GenServer)
    case GenServer.whereis(Opus.RateLimiter) do
      nil -> {:ok, _} = Opus.RateLimiter.start_link([])
      _pid -> :ok
    end

    :ok
  end

  describe "check/3" do
    test "allows requests under the limit" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      # First request should succeed with 9 remaining
      assert {:ok, 9} = RateLimiter.check(user_id, component_ref, policy)

      # Second request should succeed with 8 remaining
      assert {:ok, 8} = RateLimiter.check(user_id, component_ref, policy)

      # Reset for cleanup
      RateLimiter.reset(user_id, component_ref)
    end

    test "blocks requests over the limit" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 3, window: "1m"}}

      # Use up all 3 requests
      assert {:ok, 2} = RateLimiter.check(user_id, component_ref, policy)
      assert {:ok, 1} = RateLimiter.check(user_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(user_id, component_ref, policy)

      # Fourth request should be rate limited
      assert {:error, :rate_limited, retry_after} = RateLimiter.check(user_id, component_ref, policy)
      assert is_integer(retry_after)
      assert retry_after >= 0

      # Reset for cleanup
      RateLimiter.reset(user_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"

      # No rate limit in policy
      assert {:ok, :unlimited} = RateLimiter.check(user_id, component_ref, nil)
      assert {:ok, :unlimited} = RateLimiter.check(user_id, component_ref, %{})
      assert {:ok, :unlimited} = RateLimiter.check(user_id, component_ref, %{rate_limit: nil})
    end

    test "different users have separate limits" do
      user1 = "user_#{:rand.uniform(100_000)}"
      user2 = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # User 1 uses their limit
      assert {:ok, 1} = RateLimiter.check(user1, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(user1, component_ref, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(user1, component_ref, policy)

      # User 2 still has their full limit
      assert {:ok, 1} = RateLimiter.check(user2, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(user2, component_ref, policy)

      # Cleanup
      RateLimiter.reset(user1, component_ref)
      RateLimiter.reset(user2, component_ref)
    end

    test "different components have separate limits" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component1 = "local.component-1:1.0.0"
      component2 = "local.component-2:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up component 1's limit
      assert {:ok, 1} = RateLimiter.check(user_id, component1, policy)
      assert {:ok, 0} = RateLimiter.check(user_id, component1, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(user_id, component1, policy)

      # Component 2 still has its limit
      assert {:ok, 1} = RateLimiter.check(user_id, component2, policy)

      # Cleanup
      RateLimiter.reset(user_id, component1)
      RateLimiter.reset(user_id, component2)
    end
  end

  describe "reset/2" do
    test "resets the rate limit counter" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up the limit
      assert {:ok, 1} = RateLimiter.check(user_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(user_id, component_ref, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(user_id, component_ref, policy)

      # Reset
      :ok = RateLimiter.reset(user_id, component_ref)

      # Should have full limit again
      assert {:ok, 1} = RateLimiter.check(user_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(user_id, component_ref)
    end
  end

  describe "status/3" do
    test "returns current rate limit status" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # Check status before any requests
      assert {:ok, 0, 5, _window} = RateLimiter.status(user_id, component_ref, policy)

      # Make some requests
      {:ok, _} = RateLimiter.check(user_id, component_ref, policy)
      {:ok, _} = RateLimiter.check(user_id, component_ref, policy)

      # Status should reflect 2 requests made
      assert {:ok, 2, 3, _window} = RateLimiter.status(user_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(user_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"

      assert {:ok, :unlimited} = RateLimiter.status(user_id, component_ref, nil)
    end
  end

  describe "window parsing" do
    test "parses different window formats" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"

      # Test milliseconds
      policy_ms = %{rate_limit: %{requests: 10, window: "100ms"}}
      assert {:ok, _} = RateLimiter.check(user_id, component_ref <> "_ms", policy_ms)

      # Test seconds
      policy_s = %{rate_limit: %{requests: 10, window: "30s"}}
      assert {:ok, _} = RateLimiter.check(user_id, component_ref <> "_s", policy_s)

      # Test minutes
      policy_m = %{rate_limit: %{requests: 10, window: "5m"}}
      assert {:ok, _} = RateLimiter.check(user_id, component_ref <> "_m", policy_m)

      # Test hours
      policy_h = %{rate_limit: %{requests: 10, window: "1h"}}
      assert {:ok, _} = RateLimiter.check(user_id, component_ref <> "_h", policy_h)

      # Cleanup
      RateLimiter.reset(user_id, component_ref <> "_ms")
      RateLimiter.reset(user_id, component_ref <> "_s")
      RateLimiter.reset(user_id, component_ref <> "_m")
      RateLimiter.reset(user_id, component_ref <> "_h")
    end
  end

  describe "Sanctum.Policy struct" do
    test "works with Sanctum.Policy struct" do
      user_id = "user_#{:rand.uniform(100_000)}"
      component_ref = "local.test-component:1.0.0"

      policy = %Sanctum.Policy{
        allowed_domains: [],
        rate_limit: %{requests: 5, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      assert {:ok, 4} = RateLimiter.check(user_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(user_id, component_ref)
    end
  end
end
