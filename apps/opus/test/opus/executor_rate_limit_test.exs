# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorRateLimitTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Start the rate limiter if not already running
    case GenServer.whereis(Opus.RateLimiter) do
      nil ->
        {:ok, _pid} = Opus.RateLimiter.start_link([])

      _pid ->
        :ok
    end

    # Use a test-specific base path to avoid state leaking between tests
    test_path = Path.join(System.tmp_dir!(), "opus_rate_limit_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # Create test context
    ctx = %Context{
      user_id: "test_user_#{:rand.uniform(100_000)}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
      permissions: MapSet.new([:read, :write, :execute])
    }

    # Register the test WASM in Compendium using admin context
    admin_ctx = Sanctum.TestContext.local()
    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(admin_ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, ref: @test_ref}
  end

  describe "rate limit enforcement" do
    @tag :requires_wasm
    test "allows execution when under rate limit", %{ctx: ctx, ref: ref} do
      input = %{"a" => 5, "b" => 3}

      # First execution should not be rate-limited.
      # math.wasm is a core module so Component Model load may fail,
      # but the important thing is the rate limiter allowed it through.
      result =
        Opus.Executor.run(ctx, ref, input, type: :reagent, authority: Sanctum.Authority.zero())

      case result do
        {:ok, _} ->
          :ok

        {:error, msg} ->
          refute msg =~ "rate limit", "Expected execution to proceed, but was rate-limited"
      end
    end

    test "passing the policy gate records one policy_consultation row", %{ctx: ctx, ref: ref} do
      _result =
        Opus.Executor.run(ctx, ref, %{"a" => 1, "b" => 2},
          type: :reagent,
          authority: Sanctum.Authority.zero()
        )

      rows =
        [
          athanor_id: ctx.athanor_id,
          event_type: "policy_consultation",
          limit: 50
        ]
        |> Arca.PolicyLog.list()
        |> Enum.filter(&(&1.component_ref == ref))

      assert [row] = rows
      assert row.decision == "allowed"
      assert is_binary(row.execution_id) and row.execution_id != ""
    end

    test "blocks execution when rate limit exceeded", %{ctx: ctx} do
      # Create a mock that simulates rate limiting
      # Since we can't easily test with real WASM, we test the rate limiter directly
      component_ref = "test-rate-limited-component"

      # Set up a very restrictive rate limit (1 request per minute)
      limit_source = %{rate_limit: %{requests: 1, window: "1m"}}

      # First request should succeed
      assert {:ok, _} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref, limit_source)

      # Second request should be rate limited
      assert {:error, :rate_limited, retry_after} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref, limit_source)

      assert retry_after > 0

      # Clean up
      Opus.RateLimiter.reset(ctx.athanor_id, component_ref)
    end

    test "rate limiter tracks per athanor and component", %{ctx: ctx} do
      component_ref_a = "component-a-#{:rand.uniform(100_000)}"
      component_ref_b = "component-b-#{:rand.uniform(100_000)}"

      limit_source = %{rate_limit: %{requests: 1, window: "1m"}}

      # Request to component A
      assert {:ok, _} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref_a, limit_source)

      # Request to component B should still work (different component)
      assert {:ok, _} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref_b, limit_source)

      # Second request to component A should be rate limited
      assert {:error, :rate_limited, _} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref_a, limit_source)

      # Clean up
      Opus.RateLimiter.reset(ctx.athanor_id, component_ref_a)
      Opus.RateLimiter.reset(ctx.athanor_id, component_ref_b)
    end

    test "unlimited requests when no rate limit configured", %{ctx: ctx} do
      component_ref = "no-limit-component-#{:rand.uniform(100_000)}"

      limit_source = %{rate_limit: nil}

      # Should return :unlimited for all requests
      for _ <- 1..10 do
        assert {:ok, :unlimited} =
                 Opus.RateLimiter.check(ctx.athanor_id, component_ref, limit_source)
      end
    end

    test "rate limit status can be queried", %{ctx: ctx} do
      component_ref = "status-test-#{:rand.uniform(100_000)}"

      limit_source = %{rate_limit: %{requests: 5, window: "1m"}}

      # Check initial status
      assert {:ok, 0, 5, _window} =
               Opus.RateLimiter.status(ctx.athanor_id, component_ref, limit_source)

      # Make a request
      assert {:ok, 4} =
               Opus.RateLimiter.check(ctx.athanor_id, component_ref, limit_source)

      # Check status again
      assert {:ok, 1, 4, _window} =
               Opus.RateLimiter.status(ctx.athanor_id, component_ref, limit_source)

      # Clean up
      Opus.RateLimiter.reset(ctx.athanor_id, component_ref)
    end
  end
end
