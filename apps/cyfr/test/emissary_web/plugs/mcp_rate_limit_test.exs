# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPRateLimitTest do
  use ExUnit.Case, async: false

  alias EmissaryWeb.Plugs.MCPRateLimit

  setup do
    Cyfr.RateLimiter.reset()

    original_max = Application.get_env(:cyfr, :mcp_rate_limit_max)
    original_window = Application.get_env(:cyfr, :mcp_rate_limit_window_ms)
    original_trust = Application.get_env(:cyfr, :trust_x_forwarded_for)

    Application.put_env(:cyfr, :mcp_rate_limit_max, 3)
    Application.put_env(:cyfr, :mcp_rate_limit_window_ms, 60_000)

    on_exit(fn ->
      restore = fn
        _key, nil -> :ok
        key, value -> Application.put_env(:cyfr, key, value)
      end

      Application.delete_env(:cyfr, :mcp_rate_limit_max)
      Application.delete_env(:cyfr, :mcp_rate_limit_window_ms)
      Application.delete_env(:cyfr, :trust_x_forwarded_for)
      restore.(:mcp_rate_limit_max, original_max)
      restore.(:mcp_rate_limit_window_ms, original_window)
      restore.(:trust_x_forwarded_for, original_trust)
      Cyfr.RateLimiter.reset()
    end)

    :ok
  end

  defp conn_from(ip, path \\ "/mcp") do
    Plug.Test.conn(:post, path)
    |> Map.put(:remote_ip, ip)
  end

  test "allows requests under the limit" do
    for _ <- 1..3 do
      refute MCPRateLimit.call(conn_from({127, 0, 0, 10}), []).halted
    end
  end

  test "429s over the limit with retry-after and a JSON-RPC body" do
    ip = {127, 0, 0, 11}

    for _ <- 1..3 do
      refute MCPRateLimit.call(conn_from(ip), []).halted
    end

    blocked = MCPRateLimit.call(conn_from(ip), [])
    assert blocked.halted
    assert blocked.status == 429
    assert [retry_after] = Plug.Conn.get_resp_header(blocked, "retry-after")
    assert String.to_integer(retry_after) >= 1

    body = Jason.decode!(blocked.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["error"]["code"] == Emissary.MCP.Message.cyfr_code(:rate_limited)
    assert body["error"]["message"] =~ "Rate limit"
    assert body["id"] == nil
  end

  test "different client IPs have independent buckets" do
    for _ <- 1..3 do
      MCPRateLimit.call(conn_from({127, 0, 0, 12}), [])
    end

    refute MCPRateLimit.call(conn_from({127, 0, 0, 13}), []).halted
  end

  test "SSE GET establishment is throttled like any request" do
    ip = {127, 0, 0, 14}

    for _ <- 1..3 do
      conn = Plug.Test.conn(:get, "/mcp") |> Map.put(:remote_ip, ip)
      refute MCPRateLimit.call(conn, []).halted
    end

    conn = Plug.Test.conn(:get, "/mcp") |> Map.put(:remote_ip, ip)
    assert MCPRateLimit.call(conn, []).halted
  end

  test "keying honors the XFF trust boundary (spoofed leftmost shares the socket bucket)" do
    # Trust OFF: XFF is ignored, so varying spoofed XFF values all land in
    # the socket-IP bucket and the limit still binds.
    Application.delete_env(:cyfr, :trust_x_forwarded_for)
    ip = {127, 0, 0, 15}

    for i <- 1..3 do
      conn =
        conn_from(ip)
        |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.#{i}")

      refute MCPRateLimit.call(conn, []).halted
    end

    blocked =
      conn_from(ip)
      |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
      |> MCPRateLimit.call([])

    assert blocked.halted
    assert blocked.status == 429
  end
end
