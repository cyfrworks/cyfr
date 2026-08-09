# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.TinctureRateLimitTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.TinctureRateLimit

  setup do
    Cyfr.RateLimiter.reset()

    # config/test.exs disables the limit globally (1_000_000); exercise the
    # real per-pipeline limits here by removing the override.
    original_max = Application.get_env(:cyfr, :tincture_rate_limit_max)
    original_trust = Application.get_env(:cyfr, :trust_x_forwarded_for)
    Application.delete_env(:cyfr, :tincture_rate_limit_max)

    on_exit(fn ->
      Cyfr.RateLimiter.reset()

      restore = fn
        _key, nil -> :ok
        key, value -> Application.put_env(:cyfr, key, value)
      end

      Application.delete_env(:cyfr, :trust_x_forwarded_for)
      restore.(:tincture_rate_limit_max, original_max)
      restore.(:trust_x_forwarded_for, original_trust)
    end)

    :ok
  end

  defp opts(overrides \\ []) do
    [bucket: :test_page, max_requests: 3, window_ms: 60_000]
    |> Keyword.merge(overrides)
    |> TinctureRateLimit.init()
  end

  defp build_conn(ip \\ {127, 0, 0, 1}, tincture \\ "test-app", publisher \\ "local") do
    Plug.Test.conn(:get, "/t/local/default/#{publisher}/#{tincture}")
    |> Map.put(:remote_ip, ip)
    |> Map.put(:path_params, %{"publisher" => publisher, "tincture_name" => tincture})
  end

  describe "rate limiting" do
    test "allows requests under the limit" do
      refute TinctureRateLimit.call(build_conn(), opts()).halted
    end

    test "returns 429 when limit exceeded, with retry-after" do
      conn = build_conn()

      for _ <- 1..3 do
        refute TinctureRateLimit.call(conn, opts()).halted
      end

      result = TinctureRateLimit.call(conn, opts())
      assert result.halted
      assert result.status == 429
      assert Plug.Conn.get_resp_header(result, "retry-after") != []
    end

    test "different tinctures have independent limits" do
      for _ <- 1..3 do
        TinctureRateLimit.call(build_conn({127, 0, 0, 1}, "app-a"), opts())
      end

      refute TinctureRateLimit.call(build_conn({127, 0, 0, 1}, "app-b"), opts()).halted
    end

    test "different IPs have independent limits" do
      for _ <- 1..3 do
        TinctureRateLimit.call(build_conn({10, 0, 0, 1}), opts())
      end

      refute TinctureRateLimit.call(build_conn({10, 0, 0, 2}), opts()).halted
    end

    test "different buckets have independent limits for the same route" do
      for _ <- 1..3 do
        TinctureRateLimit.call(build_conn(), opts())
      end

      assert TinctureRateLimit.call(build_conn(), opts()).halted
      refute TinctureRateLimit.call(build_conn(), opts(bucket: :test_asset)).halted
    end

    test "falls back to path segments when path_params are absent" do
      conn =
        Plug.Test.conn(:get, "/t/local/default/pub-x/app-x/assets/app.js")
        |> Map.put(:remote_ip, {127, 0, 0, 3})

      for _ <- 1..3 do
        refute TinctureRateLimit.call(conn, opts()).halted
      end

      assert TinctureRateLimit.call(conn, opts()).halted
    end

    test "routes without tincture segments key as unknown (per-IP)" do
      conn =
        Plug.Test.conn(:get, "/t/access-token")
        |> Map.put(:remote_ip, {127, 0, 0, 4})

      for _ <- 1..3 do
        refute TinctureRateLimit.call(conn, opts()).halted
      end

      assert TinctureRateLimit.call(conn, opts()).halted
    end

    test "config override raises the effective limit" do
      Application.put_env(:cyfr, :tincture_rate_limit_max, 5)
      conn = build_conn({127, 0, 0, 5})

      for _ <- 1..5 do
        refute TinctureRateLimit.call(conn, opts()).halted
      end

      assert TinctureRateLimit.call(conn, opts()).halted
    end
  end

  describe "XFF trust boundary" do
    test "trust off (default): spoofed XFF is ignored, socket bucket binds" do
      ip = {127, 0, 0, 6}

      for i <- 1..3 do
        conn =
          build_conn(ip)
          |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.#{i}")

        refute TinctureRateLimit.call(conn, opts()).halted
      end

      blocked =
        build_conn(ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
        |> TinctureRateLimit.call(opts())

      assert blocked.halted
    end

    test "trust on: forwarded clients get independent buckets behind the proxy" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      proxy_ip = {127, 0, 0, 7}

      for _ <- 1..3 do
        conn =
          build_conn(proxy_ip)
          |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.20")

        refute TinctureRateLimit.call(conn, opts()).halted
      end

      blocked =
        build_conn(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.20")
        |> TinctureRateLimit.call(opts())

      assert blocked.halted

      fresh =
        build_conn(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.21")
        |> TinctureRateLimit.call(opts())

      refute fresh.halted
    end
  end
end
