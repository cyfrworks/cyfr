defmodule Opus.ExecutorRateLimitTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  # Sample WASM that exports a simple sum function
  @sum_wasm_path Path.expand("../../../priv/test/sum.wasm", __DIR__)

  setup do
    Arca.Cache.init()

    # Start the rate limiter if not already running
    case GenServer.whereis(Opus.RateLimiter) do
      nil ->
        {:ok, _pid} = Opus.RateLimiter.start_link([])
      _pid ->
        :ok
    end

    # Create test context
    ctx = %Context{
      user_id: "test_user_#{:rand.uniform(100_000)}",
      org_id: nil,
      scope: :local,
      permissions: [:read, :write, :execute]
    }

    {:ok, ctx: ctx}
  end

  describe "rate limit enforcement" do
    @tag :requires_wasm
    test "allows execution when under rate limit", %{ctx: ctx} do
      # Skip if test WASM doesn't exist
      unless File.exists?(@sum_wasm_path) do
        IO.puts("Skipping WASM test - test file not found at #{@sum_wasm_path}")
      else
        reference = %{"local" => @sum_wasm_path}
        input = %{"a" => 5, "b" => 3}

        # First execution should succeed
        result = Opus.Executor.run(ctx, reference, input, type: :reagent)
        assert {:ok, _} = result
      end
    end

    test "blocks execution when rate limit exceeded", %{ctx: ctx} do
      # Create a mock that simulates rate limiting
      # Since we can't easily test with real WASM, we test the rate limiter directly
      component_ref = "test-rate-limited-component"

      # Set up a very restrictive rate limit (1 request per minute)
      policy = %Sanctum.Policy{
        rate_limit: %{requests: 1, window: "1m"},
        allowed_domains: []
      }

      # First request should succeed
      assert {:ok, _} = Sanctum.Policy.check_rate_limit(policy, ctx, component_ref)

      # Second request should be rate limited
      assert {:error, :rate_limited, retry_after} =
               Sanctum.Policy.check_rate_limit(policy, ctx, component_ref)

      assert retry_after > 0

      # Clean up
      Opus.RateLimiter.reset(ctx.user_id, component_ref)
    end

    test "rate limiter tracks per user and component", %{ctx: ctx} do
      component_ref_a = "component-a-#{:rand.uniform(100_000)}"
      component_ref_b = "component-b-#{:rand.uniform(100_000)}"

      policy = %Sanctum.Policy{
        rate_limit: %{requests: 1, window: "1m"},
        allowed_domains: []
      }

      # Request to component A
      assert {:ok, _} = Sanctum.Policy.check_rate_limit(policy, ctx, component_ref_a)

      # Request to component B should still work (different component)
      assert {:ok, _} = Sanctum.Policy.check_rate_limit(policy, ctx, component_ref_b)

      # Second request to component A should be rate limited
      assert {:error, :rate_limited, _} =
               Sanctum.Policy.check_rate_limit(policy, ctx, component_ref_a)

      # Clean up
      Opus.RateLimiter.reset(ctx.user_id, component_ref_a)
      Opus.RateLimiter.reset(ctx.user_id, component_ref_b)
    end

    test "unlimited requests when no rate limit configured", %{ctx: ctx} do
      component_ref = "no-limit-component-#{:rand.uniform(100_000)}"

      policy = %Sanctum.Policy{
        rate_limit: nil,
        allowed_domains: []
      }

      # Should return :unlimited for all requests
      for _ <- 1..10 do
        assert {:ok, :unlimited} = Sanctum.Policy.check_rate_limit(policy, ctx, component_ref)
      end
    end

    test "rate limit status can be queried", %{ctx: ctx} do
      component_ref = "status-test-#{:rand.uniform(100_000)}"

      policy = %Sanctum.Policy{
        rate_limit: %{requests: 5, window: "1m"},
        allowed_domains: []
      }

      # Check initial status
      assert {:ok, 0, 5, _window} = Opus.RateLimiter.status(ctx.user_id, component_ref, policy)

      # Make a request
      assert {:ok, 4} = Sanctum.Policy.check_rate_limit(policy, ctx, component_ref)

      # Check status again
      assert {:ok, 1, 4, _window} = Opus.RateLimiter.status(ctx.user_id, component_ref, policy)

      # Clean up
      Opus.RateLimiter.reset(ctx.user_id, component_ref)
    end
  end

end
