# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Plugs.PublicRateLimitTest do
  use ExUnit.Case, async: false

  alias PrismWeb.Plugs.PublicRateLimit

  setup do
    Arca.Cache.init()
    # Clean up rate limit keys
    on_exit(fn ->
      Arca.Cache.delete_match({:rate_limit, :_, :_, :_})
    end)

    :ok
  end

  defp build_conn(ip \\ {127, 0, 0, 1}, tincture \\ "test-app", publisher \\ "local") do
    Plug.Test.conn(:get, "/public/#{publisher}/#{tincture}")
    |> Map.put(:remote_ip, ip)
    |> Map.put(:path_params, %{"publisher" => publisher, "tincture_name" => tincture})
  end

  describe "rate limiting" do
    test "allows requests under the limit" do
      conn = build_conn()
      result = PublicRateLimit.call(conn, PublicRateLimit.init([]))
      refute result.halted
    end

    test "returns 429 when limit exceeded" do
      conn = build_conn()

      # Exhaust the limit
      for _ <- 1..60 do
        result = PublicRateLimit.call(conn, PublicRateLimit.init([]))
        refute result.halted
      end

      # 61st request should be blocked
      result = PublicRateLimit.call(conn, PublicRateLimit.init([]))
      assert result.halted
      assert result.status == 429
      assert Plug.Conn.get_resp_header(result, "retry-after") != []
    end

    test "different tinctures have independent limits" do
      # Exhaust limit for app-a
      for _ <- 1..60 do
        conn = build_conn({127, 0, 0, 1}, "app-a")
        PublicRateLimit.call(conn, PublicRateLimit.init([]))
      end

      # app-b should still work
      conn = build_conn({127, 0, 0, 1}, "app-b")
      result = PublicRateLimit.call(conn, PublicRateLimit.init([]))
      refute result.halted
    end

    test "different IPs have independent limits" do
      # Exhaust limit for IP 1
      for _ <- 1..60 do
        conn = build_conn({10, 0, 0, 1}, "test-app")
        PublicRateLimit.call(conn, PublicRateLimit.init([]))
      end

      # IP 2 should still work
      conn = build_conn({10, 0, 0, 2}, "test-app")
      result = PublicRateLimit.call(conn, PublicRateLimit.init([]))
      refute result.halted
    end
  end
end
