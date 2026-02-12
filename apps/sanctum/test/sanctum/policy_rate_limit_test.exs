defmodule Sanctum.PolicyRateLimitTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy
  alias Sanctum.Context

  # These tests require Opus.RateLimiter to be running
  setup do
    # Start Opus.RateLimiter if not already running
    case Opus.RateLimiter.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ctx = Context.local()

    on_exit(fn ->
      # Reset rate limits after each test
      Opus.RateLimiter.reset(ctx.user_id, "local.test-component:1.0.0")
    end)

    {:ok, ctx: ctx}
  end

  describe "check_rate_limit/3" do
    test "returns :unlimited when rate_limit is nil", %{ctx: ctx} do
      policy = %Policy{rate_limit: nil}

      assert {:ok, :unlimited} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
    end

    test "allows requests within limit", %{ctx: ctx} do
      policy = %Policy{rate_limit: %{requests: 5, window: "1m"}}

      {:ok, remaining} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")

      assert is_integer(remaining)
      assert remaining == 4  # 5 - 1 = 4 remaining
    end

    test "tracks requests and decrements remaining", %{ctx: ctx} do
      policy = %Policy{rate_limit: %{requests: 5, window: "1m"}}

      {:ok, r1} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
      {:ok, r2} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
      {:ok, r3} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")

      assert r1 == 4
      assert r2 == 3
      assert r3 == 2
    end

    test "returns rate_limited when limit exceeded", %{ctx: ctx} do
      policy = %Policy{rate_limit: %{requests: 2, window: "1m"}}

      # Use up all requests
      {:ok, 1} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
      {:ok, 0} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")

      # Third request should be rate limited
      result = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
      assert {:error, :rate_limited, retry_after} = result
      assert is_integer(retry_after)
      assert retry_after >= 0
    end

    test "different components have separate rate limits", %{ctx: ctx} do
      policy = %Policy{rate_limit: %{requests: 2, window: "1m"}}

      # Exhaust rate limit for component1
      {:ok, _} = Policy.check_rate_limit(policy, ctx, "local.component1:1.0.0")
      {:ok, _} = Policy.check_rate_limit(policy, ctx, "local.component1:1.0.0")
      {:error, :rate_limited, _} = Policy.check_rate_limit(policy, ctx, "local.component1:1.0.0")

      # component2 should still work
      {:ok, remaining} = Policy.check_rate_limit(policy, ctx, "local.component2:1.0.0")
      assert remaining == 1

      # Clean up
      Opus.RateLimiter.reset(ctx.user_id, "local.component1:1.0.0")
      Opus.RateLimiter.reset(ctx.user_id, "local.component2:1.0.0")
    end

    test "different users have separate rate limits", %{ctx: _ctx} do
      policy = %Policy{rate_limit: %{requests: 2, window: "1m"}}

      user1_ctx = %Context{user_id: "user1", permissions: MapSet.new([:*]), scope: :personal}
      user2_ctx = %Context{user_id: "user2", permissions: MapSet.new([:*]), scope: :personal}

      # Exhaust rate limit for user1
      {:ok, _} = Policy.check_rate_limit(policy, user1_ctx, "local.shared-component:1.0.0")
      {:ok, _} = Policy.check_rate_limit(policy, user1_ctx, "local.shared-component:1.0.0")
      {:error, :rate_limited, _} = Policy.check_rate_limit(policy, user1_ctx, "local.shared-component:1.0.0")

      # user2 should still work
      {:ok, remaining} = Policy.check_rate_limit(policy, user2_ctx, "local.shared-component:1.0.0")
      assert remaining == 1

      # Clean up
      Opus.RateLimiter.reset("user1", "local.shared-component:1.0.0")
      Opus.RateLimiter.reset("user2", "local.shared-component:1.0.0")
    end

    test "respects different window sizes", %{ctx: ctx} do
      # Use a very short window for testing
      policy = %Policy{rate_limit: %{requests: 2, window: "100ms"}}

      # Use up the limit
      {:ok, _} = Policy.check_rate_limit(policy, ctx, "local.window-test:1.0.0")
      {:ok, _} = Policy.check_rate_limit(policy, ctx, "local.window-test:1.0.0")
      {:error, :rate_limited, _} = Policy.check_rate_limit(policy, ctx, "local.window-test:1.0.0")

      # Wait for window to pass
      :timer.sleep(150)

      # Should be allowed again
      {:ok, remaining} = Policy.check_rate_limit(policy, ctx, "local.window-test:1.0.0")
      assert remaining == 1

      # Clean up
      Opus.RateLimiter.reset(ctx.user_id, "local.window-test:1.0.0")
    end
  end

  describe "check_rate_limit/2 (legacy)" do
    test "returns :unlimited when rate_limit is nil" do
      policy = %Policy{rate_limit: nil}

      assert {:ok, :unlimited} = Policy.check_rate_limit(policy, "operation")
    end

    test "returns max requests without enforcement" do
      policy = %Policy{rate_limit: %{requests: 100, window: "1m"}}

      # Legacy function always returns max (no actual rate limiting)
      assert {:ok, 100} = Policy.check_rate_limit(policy, "operation")
      assert {:ok, 100} = Policy.check_rate_limit(policy, "operation")
    end
  end
end
