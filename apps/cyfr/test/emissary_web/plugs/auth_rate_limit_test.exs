# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.AuthRateLimitTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.AuthRateLimit

  setup do
    # Counters live in Cyfr.RateLimiter's own table; start each test clean.
    Cyfr.RateLimiter.reset()

    original_trust = Application.get_env(:cyfr, :trust_x_forwarded_for)

    on_exit(fn ->
      Cyfr.RateLimiter.reset()

      case original_trust do
        nil -> Application.delete_env(:cyfr, :trust_x_forwarded_for)
        value -> Application.put_env(:cyfr, :trust_x_forwarded_for, value)
      end
    end)

    :ok
  end

  defp opts do
    AuthRateLimit.init(bucket: :test_bucket, max_requests: 3, window_ms: 60_000)
  end

  defp conn_from(ip) do
    Plug.Test.conn(:get, "/")
    |> Map.put(:remote_ip, ip)
  end

  describe "rate limiting" do
    test "allows requests under the limit" do
      opts = opts()

      for _ <- 1..3 do
        result = AuthRateLimit.call(conn_from({127, 0, 0, 1}), opts)
        refute result.halted
      end
    end

    test "429s when limit exceeded, with retry-after header" do
      opts = opts()
      ip = {127, 0, 0, 2}

      for _ <- 1..3 do
        refute AuthRateLimit.call(conn_from(ip), opts).halted
      end

      blocked = AuthRateLimit.call(conn_from(ip), opts)
      assert blocked.halted
      assert blocked.status == 429
      assert [retry_after] = Plug.Conn.get_resp_header(blocked, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "different IPs have independent buckets" do
      opts = opts()

      for _ <- 1..3 do
        AuthRateLimit.call(conn_from({10, 0, 0, 1}), opts)
      end

      # Different IP: fresh window.
      result = AuthRateLimit.call(conn_from({10, 0, 0, 2}), opts)
      refute result.halted
    end

    test "different buckets have independent counters" do
      opts_a = AuthRateLimit.init(bucket: :bucket_a, max_requests: 2, window_ms: 60_000)
      opts_b = AuthRateLimit.init(bucket: :bucket_b, max_requests: 2, window_ms: 60_000)
      ip = {172, 16, 0, 1}

      for _ <- 1..2 do
        refute AuthRateLimit.call(conn_from(ip), opts_a).halted
      end

      # Bucket A exhausted for this IP but bucket B is untouched.
      assert AuthRateLimit.call(conn_from(ip), opts_a).halted
      refute AuthRateLimit.call(conn_from(ip), opts_b).halted
    end

    test "window recycle: backdating the stored tuple starts a fresh window" do
      opts = opts()
      ip = {192, 168, 1, 1}

      for _ <- 1..3 do
        AuthRateLimit.call(conn_from(ip), opts)
      end

      assert AuthRateLimit.call(conn_from(ip), opts).halted

      # Backdate the stored counter past the window so the plug opens a fresh
      # window on the next call. The Cyfr.RateLimiter row is {key, count, start}.
      key = {:rate_limit, :test_bucket, :inet.ntoa(ip) |> to_string()}
      past = System.monotonic_time(:millisecond) - 90_000
      :ets.insert(Cyfr.RateLimiter.table_name(), {key, 3, past})

      result = AuthRateLimit.call(conn_from(ip), opts)
      refute result.halted
    end
  end

  describe "XFF trust boundary" do
    test "trust off (default): spoofed XFF is ignored, socket bucket binds" do
      Application.delete_env(:cyfr, :trust_x_forwarded_for)
      opts = opts()
      ip = {127, 0, 0, 21}

      for i <- 1..3 do
        conn =
          conn_from(ip)
          |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.#{i}")

        refute AuthRateLimit.call(conn, opts).halted
      end

      blocked =
        conn_from(ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
        |> AuthRateLimit.call(opts)

      assert blocked.halted
      assert blocked.status == 429
    end

    test "trust on: forwarded clients get independent buckets behind the proxy" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      opts = opts()
      proxy_ip = {127, 0, 0, 22}

      # Exhaust client A's bucket through the proxy.
      for _ <- 1..3 do
        conn =
          conn_from(proxy_ip)
          |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.10")

        refute AuthRateLimit.call(conn, opts).halted
      end

      blocked =
        conn_from(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.10")
        |> AuthRateLimit.call(opts)

      assert blocked.halted

      # Client B behind the same proxy still has a fresh bucket.
      other =
        conn_from(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.11")
        |> AuthRateLimit.call(opts)

      refute other.halted
    end
  end
end
