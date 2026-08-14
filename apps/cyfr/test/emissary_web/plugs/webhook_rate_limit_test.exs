# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.WebhookRateLimitTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.WebhookRateLimit

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp build_conn(slug, remote_ip \\ {127, 0, 0, 1}) do
    Plug.Test.conn(:post, "/hooks/" <> slug, "{}")
    |> Map.put(:path_params, %{"slug" => slug})
    |> Map.put(:remote_ip, remote_ip)
  end

  defp create_webhook!(ctx, name, opts \\ %{}) do
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{})
    Sanctum.Test.ConsentFixtures.start_source!()
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.h")
    attrs = Map.merge(%{name: name, target_ref: "f:local.h", profile_id: profile}, opts)
    {:ok, result} = Sanctum.Webhook.create(ctx, attrs)
    result.slug
  end

  describe "known, enabled slug" do
    test "passes through under default 100/min", %{ctx: ctx} do
      slug = create_webhook!(ctx, "rl-pass-#{:rand.uniform(1_000_000)}")
      conn = build_conn(slug)

      Enum.each(1..10, fn _ ->
        result = WebhookRateLimit.call(conn, %{})
        refute result.halted
      end)
    end

    test "halts with 429 after 100 requests in window", %{ctx: ctx} do
      slug = create_webhook!(ctx, "rl-cap-#{:rand.uniform(1_000_000)}")
      conn = build_conn(slug)

      statuses =
        for _ <- 1..120 do
          WebhookRateLimit.call(conn, %{}).status
        end

      accepted = Enum.count(statuses, &is_nil/1)
      rate_limited = Enum.count(statuses, &(&1 == 429))

      assert accepted >= 99
      assert accepted <= 100
      assert rate_limited >= 20
    end

    test "different slugs get isolated buckets", %{ctx: ctx} do
      slug_a = create_webhook!(ctx, "rl-isolated-a-#{:rand.uniform(1_000_000)}")
      slug_b = create_webhook!(ctx, "rl-isolated-b-#{:rand.uniform(1_000_000)}")

      # Saturate A; B must still pass.
      conn_a = build_conn(slug_a)
      Enum.each(1..101, fn _ -> WebhookRateLimit.call(conn_a, %{}) end)

      conn_b = build_conn(slug_b)
      refute WebhookRateLimit.call(conn_b, %{}).halted
    end

    test "honors per-webhook rate_limit override", %{ctx: ctx} do
      name = "rl-tight-#{:rand.uniform(1_000_000)}"
      slug = create_webhook!(ctx, name, %{rate_limit: "5/1m"})
      conn = build_conn(slug)

      statuses =
        for _ <- 1..10 do
          WebhookRateLimit.call(conn, %{}).status
        end

      accepted = Enum.count(statuses, &is_nil/1)
      assert accepted >= 4
      assert accepted <= 5
    end
  end

  describe "unknown or disabled slug — scan-evasion bucket" do
    test "limits unknown slugs to 10/min keyed by IP" do
      slug = "wh_does_not_exist_#{:rand.uniform(1_000_000_000)}"
      conn = build_conn(slug, {10, 0, 0, 1})

      statuses =
        for _ <- 1..15 do
          WebhookRateLimit.call(conn, %{}).status
        end

      accepted = Enum.count(statuses, &is_nil/1)
      rate_limited = Enum.count(statuses, &(&1 == 429))

      assert accepted >= 9
      assert accepted <= 10
      assert rate_limited >= 5
    end

    test "different unknown slugs from same IP share the bucket (no enumeration evasion)" do
      ip = {10, 0, 0, 2}

      # Saturate the IP bucket via slug A.
      conn_a = build_conn("wh_unknown_a_#{:rand.uniform(1_000_000_000)}", ip)
      Enum.each(1..11, fn _ -> WebhookRateLimit.call(conn_a, %{}) end)

      # Slug B from same IP should be rate-limited.
      conn_b = build_conn("wh_unknown_b_#{:rand.uniform(1_000_000_000)}", ip)
      result = WebhookRateLimit.call(conn_b, %{})
      assert result.halted
      assert result.status == 429
    end

    test "different IPs get isolated unknown-slug buckets" do
      conn_a = build_conn("wh_unknown_#{:rand.uniform(1_000_000_000)}", {10, 0, 0, 3})
      Enum.each(1..11, fn _ -> WebhookRateLimit.call(conn_a, %{}) end)

      conn_b = build_conn("wh_unknown_#{:rand.uniform(1_000_000_000)}", {10, 0, 0, 4})
      refute WebhookRateLimit.call(conn_b, %{}).halted
    end

    test "disabled webhook routes to scan-evasion bucket (10/min)", %{ctx: ctx} do
      name = "rl-disabled-#{:rand.uniform(1_000_000)}"
      slug = create_webhook!(ctx, name)
      :ok = Sanctum.Webhook.revoke(ctx, name)

      conn = build_conn(slug, {10, 0, 0, 50})

      statuses =
        for _ <- 1..15 do
          WebhookRateLimit.call(conn, %{}).status
        end

      accepted = Enum.count(statuses, &is_nil/1)
      assert accepted <= 10
      assert Enum.count(statuses, &(&1 == 429)) >= 5
    end
  end

  describe "no slug" do
    test "falls back to IP scan-evasion bucket" do
      conn =
        Plug.Test.conn(:post, "/hooks/", "{}")
        |> Map.put(:remote_ip, {10, 0, 0, 99})

      statuses =
        for _ <- 1..15 do
          WebhookRateLimit.call(conn, %{}).status
        end

      accepted = Enum.count(statuses, &is_nil/1)
      assert accepted <= 10
    end
  end
end
