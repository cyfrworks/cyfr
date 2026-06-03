# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Opus.RateLimiter

  # Rate limits are keyed by {org_id, project_id, component_ref}; members of a
  # project share its budget. Tests pass a concrete org explicitly (there is no
  # implicit default) and randomize the project so cases never collide.
  @org "rl_test_org"

  defp project, do: "project_#{:rand.uniform(100_000)}"

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

  describe "check/4" do
    test "allows requests under the limit" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      # First request should succeed with 9 remaining
      assert {:ok, 9} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Second request should succeed with 8 remaining
      assert {:ok, 8} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Reset for cleanup
      RateLimiter.reset(@org, project_id, component_ref)
    end

    test "blocks requests over the limit" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 3, window: "1m"}}

      # Use up all 3 requests
      assert {:ok, 2} = RateLimiter.check(@org, project_id, component_ref, policy)
      assert {:ok, 1} = RateLimiter.check(@org, project_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Fourth request should be rate limited
      assert {:error, :rate_limited, retry_after} =
               RateLimiter.check(@org, project_id, component_ref, policy)

      assert is_integer(retry_after)
      assert retry_after >= 0

      # Reset for cleanup
      RateLimiter.reset(@org, project_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"

      # No rate limit in policy
      assert {:ok, :unlimited} = RateLimiter.check(@org, project_id, component_ref, nil)
      assert {:ok, :unlimited} = RateLimiter.check(@org, project_id, component_ref, %{})
      assert {:ok, :unlimited} = RateLimiter.check(@org, project_id, component_ref, %{rate_limit: nil})
    end

    test "different projects have separate limits" do
      project_1 = project()
      project_2 = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Project 1 uses its limit
      assert {:ok, 1} = RateLimiter.check(@org, project_1, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(@org, project_1, component_ref, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(@org, project_1, component_ref, policy)

      # Project 2 still has its full limit
      assert {:ok, 1} = RateLimiter.check(@org, project_2, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(@org, project_2, component_ref, policy)

      # Cleanup
      RateLimiter.reset(@org, project_1, component_ref)
      RateLimiter.reset(@org, project_2, component_ref)
    end

    test "the same project+component in different orgs has separate limits" do
      # Tenant isolation: two orgs sharing the same project id and component must
      # not share a rate-limit budget. Exhausting one must not touch the other.
      org_a = "org_a_#{:rand.uniform(100_000)}"
      org_b = "org_b_#{:rand.uniform(100_000)}"
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # org_a exhausts its budget
      assert {:ok, 1} = RateLimiter.check(org_a, project_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(org_a, project_id, component_ref, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(org_a, project_id, component_ref, policy)

      # org_b is untouched — full budget despite identical project + component
      assert {:ok, 1} = RateLimiter.check(org_b, project_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(org_b, project_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(org_a, project_id, component_ref)
      RateLimiter.reset(org_b, project_id, component_ref)
    end

    test "different components have separate limits" do
      project_id = project()
      component1 = "local.component-1:1.0.0"
      component2 = "local.component-2:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up component 1's limit
      assert {:ok, 1} = RateLimiter.check(@org, project_id, component1, policy)
      assert {:ok, 0} = RateLimiter.check(@org, project_id, component1, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(@org, project_id, component1, policy)

      # Component 2 still has its limit
      assert {:ok, 1} = RateLimiter.check(@org, project_id, component2, policy)

      # Cleanup
      RateLimiter.reset(@org, project_id, component1)
      RateLimiter.reset(@org, project_id, component2)
    end
  end

  describe "reset/3" do
    test "resets the rate limit counter" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 2, window: "1m"}}

      # Use up the limit
      assert {:ok, 1} = RateLimiter.check(@org, project_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(@org, project_id, component_ref, policy)
      assert {:error, :rate_limited, _} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Reset
      :ok = RateLimiter.reset(@org, project_id, component_ref)

      # Should have full limit again
      assert {:ok, 1} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(@org, project_id, component_ref)
    end
  end

  describe "status/4" do
    test "returns current rate limit status" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 5, window: "1m"}}

      # Check status before any requests
      assert {:ok, 0, 5, _window} = RateLimiter.status(@org, project_id, component_ref, policy)

      # Make some requests
      {:ok, _} = RateLimiter.check(@org, project_id, component_ref, policy)
      {:ok, _} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Status should reflect 2 requests made
      assert {:ok, 2, 3, _window} = RateLimiter.status(@org, project_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(@org, project_id, component_ref)
    end

    test "returns unlimited when no rate limit configured" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"

      assert {:ok, :unlimited} = RateLimiter.status(@org, project_id, component_ref, nil)
    end
  end

  describe "window parsing" do
    test "parses different window formats" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"

      # Test milliseconds
      policy_ms = %{rate_limit: %{requests: 10, window: "100ms"}}
      assert {:ok, _} = RateLimiter.check(@org, project_id, component_ref <> "_ms", policy_ms)

      # Test seconds
      policy_s = %{rate_limit: %{requests: 10, window: "30s"}}
      assert {:ok, _} = RateLimiter.check(@org, project_id, component_ref <> "_s", policy_s)

      # Test minutes
      policy_m = %{rate_limit: %{requests: 10, window: "5m"}}
      assert {:ok, _} = RateLimiter.check(@org, project_id, component_ref <> "_m", policy_m)

      # Test hours
      policy_h = %{rate_limit: %{requests: 10, window: "1h"}}
      assert {:ok, _} = RateLimiter.check(@org, project_id, component_ref <> "_h", policy_h)

      # Cleanup
      RateLimiter.reset(@org, project_id, component_ref <> "_ms")
      RateLimiter.reset(@org, project_id, component_ref <> "_s")
      RateLimiter.reset(@org, project_id, component_ref <> "_m")
      RateLimiter.reset(@org, project_id, component_ref <> "_h")
    end
  end

  describe "tenant (org_id) enforcement" do
    test "check rejects empty org_id in multi-tenant" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.check("", project_id, component_ref, policy)
    end

    test "check rejects nil org_id in multi-tenant" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.check(nil, project_id, component_ref, policy)
    end

    test "reset rejects empty org_id in multi-tenant" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"

      assert {:error, :missing_tenant} = RateLimiter.reset("", project_id, component_ref)
    end

    test "status rejects empty org_id in multi-tenant" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:error, :missing_tenant} = RateLimiter.status("", project_id, component_ref, policy)
    end

    test "check allows non-empty org_id in multi-tenant" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"
      policy = %{rate_limit: %{requests: 10, window: "1m"}}

      assert {:ok, 9} = RateLimiter.check("org_ext_test", project_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset("org_ext_test", project_id, component_ref)
    end
  end

  describe "Sanctum.Policy struct" do
    test "works with Sanctum.Policy struct" do
      project_id = project()
      component_ref = "local.test-component:1.0.0"

      policy = %Sanctum.Policy{
        allowed_domains: [],
        rate_limit: %{requests: 5, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      assert {:ok, 4} = RateLimiter.check(@org, project_id, component_ref, policy)

      # Cleanup
      RateLimiter.reset(@org, project_id, component_ref)
    end
  end
end
