# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RateLimiterTest do
  use ExUnit.Case, async: false

  import Opus.TestWait

  alias Opus.RateLimiter

  # Rate limits are keyed by {athanor_id, component_ref}; members of an
  # athanor share its budget. Tests randomize the athanor so cases never
  # collide.
  defp athanor, do: "ath_rl_#{:rand.uniform(100_000)}"

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
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      # First request should succeed with 9 remaining
      assert {:ok, 9} = RateLimiter.check(athanor_id, component_ref, policy)

      # Second request should succeed with 8 remaining
      assert {:ok, 8} = RateLimiter.check(athanor_id, component_ref, policy)

      # Reset for cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end

    test "blocks requests over the limit" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 3, window: "1m"}}

      # Use up all 3 requests
      assert {:ok, 2} = RateLimiter.check(athanor_id, component_ref, policy)
      assert {:ok, 1} = RateLimiter.check(athanor_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_id, component_ref, policy)

      # Fourth request should be rate limited
      assert {:error, :rate_limited, retry_after} =
               RateLimiter.check(athanor_id, component_ref, policy)

      assert is_integer(retry_after)
      assert retry_after >= 0

      # Reset for cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      # No rate limit in policy
      assert {:ok, :unlimited} = RateLimiter.check(athanor_id, component_ref, nil)
      assert {:ok, :unlimited} = RateLimiter.check(athanor_id, component_ref, %{})

      assert {:ok, :unlimited} =
               RateLimiter.check(athanor_id, component_ref, %{rate_limit: nil})
    end

    test "different athanors have separate limits" do
      athanor_1 = athanor()
      athanor_2 = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Athanor 1 uses its limit
      assert {:ok, 1} = RateLimiter.check(athanor_1, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_1, component_ref, policy)

      assert {:error, :rate_limited, _} =
               RateLimiter.check(athanor_1, component_ref, policy)

      # Athanor 2 still has its full limit
      assert {:ok, 1} = RateLimiter.check(athanor_2, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_2, component_ref, policy)

      # Cleanup
      RateLimiter.reset(athanor_1, component_ref)
      RateLimiter.reset(athanor_2, component_ref)
    end

    test "the same component in different athanors has separate limits" do
      # Tenant isolation: two athanors sharing a component must not share a
      # rate-limit budget. Exhausting one must not touch the other.
      athanor_a = athanor()
      athanor_b = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # athanor_a exhausts its budget
      assert {:ok, 1} = RateLimiter.check(athanor_a, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_a, component_ref, policy)

      assert {:error, :rate_limited, _} =
               RateLimiter.check(athanor_a, component_ref, policy)

      # athanor_b is untouched
      assert {:ok, 1} = RateLimiter.check(athanor_b, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_b, component_ref, policy)

      # Cleanup
      RateLimiter.reset(athanor_a, component_ref)
      RateLimiter.reset(athanor_b, component_ref)
    end

    test "different components have separate limits" do
      athanor_id = athanor()
      component1 = "local.component-1:1.0.0"
      component2 = "local.component-2:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up component 1's limit
      assert {:ok, 1} = RateLimiter.check(athanor_id, component1, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_id, component1, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(athanor_id, component1, policy)

      # Component 2 still has its limit
      assert {:ok, 1} = RateLimiter.check(athanor_id, component2, policy)

      # Cleanup
      RateLimiter.reset(athanor_id, component1)
      RateLimiter.reset(athanor_id, component2)
    end
  end

  describe "reset/3" do
    test "resets the rate limit counter" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up the limit
      assert {:ok, 1} = RateLimiter.check(athanor_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(athanor_id, component_ref, policy)

      assert {:error, :rate_limited, _} =
               RateLimiter.check(athanor_id, component_ref, policy)

      # Reset
      :ok = RateLimiter.reset(athanor_id, component_ref)

      # Should have full limit again
      assert {:ok, 1} = RateLimiter.check(athanor_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end
  end

  describe "status/3" do
    test "returns current rate limit status" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # Check status before any requests
      assert {:ok, 0, 5, _window} = RateLimiter.status(athanor_id, component_ref, policy)

      # Make some requests
      {:ok, _} = RateLimiter.check(athanor_id, component_ref, policy)
      {:ok, _} = RateLimiter.check(athanor_id, component_ref, policy)

      # Status should reflect 2 requests made
      assert {:ok, 2, 3, _window} = RateLimiter.status(athanor_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      assert {:ok, :unlimited} = RateLimiter.status(athanor_id, component_ref, nil)
    end
  end

  describe "window parsing" do
    test "parses different window formats" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      # Test milliseconds
      policy_ms = %{rate_limit: %{requests: 10, window: "100ms"}}
      assert {:ok, _} = RateLimiter.check(athanor_id, component_ref <> "_ms", policy_ms)

      # Test seconds
      policy_s = %{rate_limit: %{requests: 10, window: "30s"}}
      assert {:ok, _} = RateLimiter.check(athanor_id, component_ref <> "_s", policy_s)

      # Test minutes
      policy_m = %{rate_limit: %{requests: 10, window: "5m"}}
      assert {:ok, _} = RateLimiter.check(athanor_id, component_ref <> "_m", policy_m)

      # Test hours
      policy_h = %{rate_limit: %{requests: 10, window: "1h"}}
      assert {:ok, _} = RateLimiter.check(athanor_id, component_ref <> "_h", policy_h)

      # Cleanup
      RateLimiter.reset(athanor_id, component_ref <> "_ms")
      RateLimiter.reset(athanor_id, component_ref <> "_s")
      RateLimiter.reset(athanor_id, component_ref <> "_m")
      RateLimiter.reset(athanor_id, component_ref <> "_h")
    end
  end

  describe "tenant (athanor_id) enforcement" do
    test "check rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.check("", component_ref, policy)
    end

    test "check rejects a nil athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.check(nil, component_ref, policy)
    end

    test "reset rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"

      assert {:error, :missing_tenant} = RateLimiter.reset("", component_ref)
    end

    test "status rejects an empty athanor_id" do
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.status("", component_ref, policy)
    end

    test "check allows a resolved athanor_id" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:ok, 9} = RateLimiter.check(athanor_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end
  end

  describe "Sanctum.Limits struct" do
    test "works with a Sanctum.Limits struct as the limit source" do
      athanor_id = athanor()
      component_ref = "local.test-component:1.0.0"

      limits = %Sanctum.Limits{
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880,
        rate_limit: %{requests: 5, window: "1m"},
        max_concurrent_tasks: 10,
        batch_timeout: "5m"
      }

      assert {:ok, 4} = RateLimiter.check(athanor_id, component_ref, limits)

      # Cleanup
      RateLimiter.reset(athanor_id, component_ref)
    end
  end

  describe "concurrency" do
    test "concurrent checks stay within a bounded overshoot of the limit" do
      athanor_id = athanor()
      component_ref = "local.concurrent-#{:rand.uniform(100_000)}:1.0.0"
      policy = %{rate_limit: %{requests: 50, window: "1m"}}

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..10 do
              RateLimiter.check(athanor_id, component_ref, policy)
            end
          end)
        end)
        |> Enum.flat_map(&Task.await(&1, 10_000))

      allowed = Enum.count(results, &match?({:ok, _}, &1))

      # Non-atomic count-then-insert may overshoot by up to the number of
      # simultaneous callers; it must never undershoot.
      assert allowed >= 50
      assert allowed <= 50 + 20

      # The window is saturated: a subsequent check denies.
      assert {:error, :rate_limited, _} =
               RateLimiter.check(athanor_id, component_ref, policy)

      RateLimiter.reset(athanor_id, component_ref)
    end
  end

  describe "fail-closed on dead limiter" do
    test "a dead limiter exits like a dead GenServer so Policy denies" do
      athanor_id = athanor()
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # In an umbrella run the limiter is supervised, and a plain
      # GenServer.stop races the supervisor's automatic restart. Park the
      # child via terminate_child (no auto-restart) so the dead-table window
      # is deterministic; fall back to stop/start when unsupervised.
      supervised? =
        Process.whereis(Opus.Supervisor) != nil and
          match?(:ok, Supervisor.terminate_child(Opus.Supervisor, RateLimiter))

      unless supervised?, do: GenServer.stop(RateLimiter)

      assert {:noproc, {RateLimiter, :check}} =
               catch_exit(RateLimiter.check(athanor_id, "local.dead:1.0.0", policy))

      # Restore the limiter (and its table) for the rest of the suite.
      if supervised? do
        {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, RateLimiter)
      else
        {:ok, _pid} = RateLimiter.start_link([])
      end

      wait_until(fn -> :ets.whereis(:opus_rate_limiter) != :undefined end)
    end
  end
end
