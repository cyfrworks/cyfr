# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.TinctureRateLimitTest do
  use ExUnit.Case, async: false

  alias CyfrWeb.Plugs.TinctureRateLimit

  setup do
    Prima.Test.RateLimiter.reset!()

    # config/test.exs disables the limit globally (1_000_000); exercise the
    # real per-pipeline limits here by removing the override.
    original_max = Application.get_env(:cyfr, :tincture_rate_limit_max)
    original_trust = Application.get_env(:sanctum, :proxy_trust)
    Application.delete_env(:cyfr, :tincture_rate_limit_max)

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()

      restore = fn
        _app, _key, nil -> :ok
        app, key, value -> Application.put_env(app, key, value)
      end

      Application.delete_env(:sanctum, :proxy_trust)
      restore.(:cyfr, :tincture_rate_limit_max, original_max)
      restore.(:sanctum, :proxy_trust, original_trust)
    end)

    :ok
  end

  defmodule Renderer do
    @moduledoc false
    @behaviour CyfrWeb.ErrorRenderer

    @impl true
    def send(conn, status, reason, _message),
      do: Plug.Conn.send_resp(conn, status, "rendered #{reason}")

    @impl true
    def halt(conn, status, reason, message),
      do: conn |> send(status, reason, message) |> Plug.Conn.halt()
  end

  defp opts(overrides \\ []) do
    [bucket: :test_page, max_requests: 3, window_ms: 60_000]
    |> Keyword.merge(overrides)
    |> TinctureRateLimit.init()
  end

  # A request on the tincture route, with the params its match binds.
  defp build_conn(ip \\ {127, 0, 0, 1}, tincture \\ "test-app", publisher \\ "local") do
    Plug.Test.conn(:get, "/t/home/#{publisher}/#{tincture}")
    |> Map.put(:remote_ip, ip)
    |> Map.put(:path_params, %{
      "athanor" => "home",
      "publisher" => publisher,
      "tincture_name" => tincture
    })
  end

  # A request the proxy listener accepted, the one listener whose
  # forwarded headers are read.
  defp proxied(ip), do: ip |> build_conn() |> Sanctum.ClientIp.put_ingress(:proxy)

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

    test "two athanors hosting the same publisher and name have independent limits" do
      for _ <- 1..3 do
        TinctureRateLimit.call(build_conn({127, 0, 0, 3}), opts())
      end

      other =
        {127, 0, 0, 3}
        |> build_conn()
        |> Map.update!(:path_params, &Map.put(&1, "athanor", "other"))

      assert TinctureRateLimit.call(build_conn({127, 0, 0, 3}), opts()).halted
      refute TinctureRateLimit.call(other, opts()).halted
    end

    test "routes without the tincture route's params key as unknown (per-IP)" do
      conn =
        Plug.Test.conn(:post, "/_f/v1/invoke")
        |> Map.put(:remote_ip, {127, 0, 0, 4})

      for _ <- 1..3 do
        refute TinctureRateLimit.call(conn, opts()).halted
      end

      assert TinctureRateLimit.call(conn, opts()).halted
      refute TinctureRateLimit.call(Map.put(conn, :remote_ip, {127, 0, 0, 44}), opts()).halted
    end

    test "a private version's files key per asset credential, whatever the address" do
      served = fn credential, ip ->
        Plug.Test.conn(:get, "/_s/#{credential}/local/dash/1.0.0/app.js")
        |> Map.put(:remote_ip, ip)
      end

      mine = String.duplicate("a", 24)
      theirs = String.duplicate("b", 24)

      for n <- 1..3 do
        refute TinctureRateLimit.call(served.(mine, {127, 0, 1, n}), opts()).halted
      end

      # Another address does not refill the credential's budget, and
      # another credential from the same address has its own.
      assert TinctureRateLimit.call(served.(mine, {127, 0, 1, 9}), opts()).halted
      refute TinctureRateLimit.call(served.(theirs, {127, 0, 1, 1}), opts()).halted
    end

    test "a refusal renders through the pipeline's renderer" do
      conn = build_conn({127, 0, 0, 7})

      for _ <- 1..3, do: TinctureRateLimit.call(conn, opts(errors: __MODULE__.Renderer))

      result = TinctureRateLimit.call(conn, opts(errors: __MODULE__.Renderer))
      assert result.halted
      assert result.resp_body == "rendered rate_limited"
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
      # One proxy in front of the proxy listener, as `config/runtime.exs`
      # configures the trust.
      Application.put_env(:sanctum, :proxy_trust, {:hops, 1})
      proxy_ip = {127, 0, 0, 7}

      for _ <- 1..3 do
        conn =
          proxied(proxy_ip)
          |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.20")

        refute TinctureRateLimit.call(conn, opts()).halted
      end

      blocked =
        proxied(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.20")
        |> TinctureRateLimit.call(opts())

      assert blocked.halted

      fresh =
        proxied(proxy_ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.21")
        |> TinctureRateLimit.call(opts())

      refute fresh.halted
    end
  end
end
