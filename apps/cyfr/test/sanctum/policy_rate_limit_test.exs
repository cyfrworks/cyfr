# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PolicyRateLimitTest do
  use ExUnit.Case, async: false
  @moduletag :requires_opus

  alias Sanctum.Policy
  alias Sanctum.Context

  # These tests require Opus.RateLimiter to be running
  setup do
    # Start Opus.RateLimiter if not already running
    case Opus.RateLimiter.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      # Reset rate limits after each test
      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, "local.test-component:1.0.0")
    end)

    {:ok, ctx: ctx}
  end

  describe "check_rate_limit/3" do
    test "returns :unlimited when rate_limit is nil", %{ctx: ctx} do
      policy = %Policy{rate_limit: nil}

      assert {:ok, :unlimited} =
               Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")
    end

    test "allows requests within limit", %{ctx: ctx} do
      policy = %Policy{rate_limit: %{requests: 5, window: "1m"}}

      {:ok, remaining} = Policy.check_rate_limit(policy, ctx, "local.test-component:1.0.0")

      assert is_integer(remaining)
      # 5 - 1 = 4 remaining
      assert remaining == 4
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

    test "denied checks record a rate_limit enforcement row", %{ctx: ctx} do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      ref = "local.audited-rl:1.0.0"
      policy = %Policy{rate_limit: %{requests: 1, window: "1m"}}

      {:ok, 0} = Policy.check_rate_limit(policy, ctx, ref)
      assert {:error, :rate_limited, _} = Policy.check_rate_limit(policy, ctx, ref)

      rows =
        [org_id: ctx.org_id, project_id: ctx.project_id, limit: 50]
        |> Arca.PolicyLog.list()
        |> Enum.filter(&(&1.component_ref == ref))

      assert [row] = rows
      assert row.event_type == "rate_limit"
      assert row.decision == "denied"
      assert row.decision_reason =~ "rate limit exceeded"

      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, ref)
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
      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, "local.component1:1.0.0")
      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, "local.component2:1.0.0")
    end

    test "different projects have separate rate limits", %{ctx: _ctx} do
      # Rate limits are keyed by (org, project) — members of a project share the
      # budget, but distinct projects are isolated. (Two users in the same
      # project would share; that is intentional, so this asserts project-level
      # isolation, not user-level.)
      policy = %Policy{rate_limit: %{requests: 2, window: "1m"}}

      project_a_ctx = %Context{
        user_id: "user1",
        org_id: "local",
        project_id: "proj_a",
        permissions: MapSet.new([:*]),
        scope: :project
      }

      project_b_ctx = %Context{
        user_id: "user2",
        org_id: "local",
        project_id: "proj_b",
        permissions: MapSet.new([:*]),
        scope: :project
      }

      # Exhaust rate limit for project A
      {:ok, _} = Policy.check_rate_limit(policy, project_a_ctx, "local.shared-component:1.0.0")
      {:ok, _} = Policy.check_rate_limit(policy, project_a_ctx, "local.shared-component:1.0.0")

      {:error, :rate_limited, _} =
        Policy.check_rate_limit(policy, project_a_ctx, "local.shared-component:1.0.0")

      # project B should still work — separate budget
      {:ok, remaining} =
        Policy.check_rate_limit(policy, project_b_ctx, "local.shared-component:1.0.0")

      assert remaining == 1

      # Clean up
      Opus.RateLimiter.reset("local", "proj_a", "local.shared-component:1.0.0")
      Opus.RateLimiter.reset("local", "proj_b", "local.shared-component:1.0.0")
    end

    test "different user_ids in one project share a single bucket", %{ctx: ctx} do
      # The limiter keys on {org, project, component_ref} and ignores
      # ctx.user_id entirely — all public callers of one tincture share one
      # bucket. The tincture controller's "ip:<addr>" user_id rewrite is
      # audit attribution only, never per-client bucketing; this test locks
      # that in so the rewrite can't silently be mistaken for isolation.
      policy = %Policy{rate_limit: %{requests: 2, window: "1m"}}
      ref = "local.shared-bucket:1.0.0"

      ip_a_ctx = %Context{ctx | user_id: "ip:198.51.100.1"}
      ip_b_ctx = %Context{ctx | user_id: "ip:203.0.113.9"}

      {:ok, _} = Policy.check_rate_limit(policy, ip_a_ctx, ref)
      {:ok, _} = Policy.check_rate_limit(policy, ip_a_ctx, ref)

      # A different "client" draws from the same exhausted bucket
      assert {:error, :rate_limited, _} = Policy.check_rate_limit(policy, ip_b_ctx, ref)

      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, ref)
    end

    test "denial audit rows carry the caller's user_id for attribution", %{ctx: ctx} do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      ref = "local.attributed-rl:1.0.0"
      policy = %Policy{rate_limit: %{requests: 1, window: "1m"}}
      ip_ctx = %Context{ctx | user_id: "ip:198.51.100.7"}

      {:ok, 0} = Policy.check_rate_limit(policy, ip_ctx, ref)
      assert {:error, :rate_limited, _} = Policy.check_rate_limit(policy, ip_ctx, ref)

      rows =
        [org_id: ctx.org_id, project_id: ctx.project_id, limit: 50]
        |> Arca.PolicyLog.list()
        |> Enum.filter(&(&1.component_ref == ref))

      assert [row] = rows
      assert row.user_id == "ip:198.51.100.7"

      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, ref)
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
      Opus.RateLimiter.reset(ctx.org_id, ctx.project_id, "local.window-test:1.0.0")
    end
  end
end
