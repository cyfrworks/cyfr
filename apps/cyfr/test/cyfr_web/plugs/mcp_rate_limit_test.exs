# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.MCPRateLimitTest do
  use ExUnit.Case, async: false

  alias Cyfr.Test.Settings
  alias CyfrWeb.Plugs.MCPRateLimit

  setup do
    Prima.RateLimiter.reset()

    original_trust = Application.get_env(:sanctum, :trust_x_forwarded_for)

    Settings.put("mcp_rate_limit_max", 3)
    Settings.put("mcp_rate_limit_window_ms", 60_000)

    on_exit(fn ->
      Application.delete_env(:sanctum, :trust_x_forwarded_for)

      if original_trust != nil,
        do: Application.put_env(:sanctum, :trust_x_forwarded_for, original_trust)

      Prima.RateLimiter.reset()
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
      refute MCPRateLimit.call(conn_from(ip), errors: Emissary.Web.MCPError).halted
    end

    blocked = MCPRateLimit.call(conn_from(ip), errors: Emissary.Web.MCPError)
    assert blocked.halted
    assert blocked.status == 429
    assert [retry_after] = Plug.Conn.get_resp_header(blocked, "retry-after")
    assert String.to_integer(retry_after) >= 1

    body = Jason.decode!(blocked.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["error"]["code"] == Prima.MCP.Message.error_code(:rate_limited)
    assert body["error"]["message"] =~ "Rate limit"
    assert body["id"] == nil
  end

  test "without a renderer the 429 is a plain JSON refusal" do
    ip = {127, 0, 0, 16}

    for _ <- 1..3 do
      refute MCPRateLimit.call(conn_from(ip), MCPRateLimit.init([])).halted
    end

    blocked = MCPRateLimit.call(conn_from(ip), MCPRateLimit.init([]))
    assert blocked.status == 429

    body = Jason.decode!(blocked.resp_body)
    assert body["code"] == "rate_limited"
    refute Map.has_key?(body, "jsonrpc")
  end

  test "a limit set takes the next request, with no restart" do
    ip = {127, 0, 0, 20}

    for _ <- 1..3, do: refute(MCPRateLimit.call(conn_from(ip), []).halted)
    assert MCPRateLimit.call(conn_from(ip), []).halted

    Settings.put("mcp_rate_limit_max", 5)

    for _ <- 1..2, do: refute(MCPRateLimit.call(conn_from(ip), []).halted)
    assert MCPRateLimit.call(conn_from(ip), []).halted
  end

  test "the :api bucket takes the MCP pair while its own is unset, and its own once set" do
    api = MCPRateLimit.init(bucket: :api)
    ip = {127, 0, 0, 21}

    for _ <- 1..3, do: refute(MCPRateLimit.call(conn_from(ip, "/api/x"), api).halted)
    assert MCPRateLimit.call(conn_from(ip, "/api/x"), api).halted

    Settings.put("api_rate_limit_max", 4)
    refute MCPRateLimit.call(conn_from(ip, "/api/x"), api).halted
    assert MCPRateLimit.call(conn_from(ip, "/api/x"), api).halted

    # Reset deletes the row: absent again, the pair inherits once more.
    Settings.reset("api_rate_limit_max")
    assert Arca.PlatformSettings.get("api_rate_limit_max") == {:error, :not_found}
    assert MCPRateLimit.call(conn_from(ip, "/api/x"), api).halted
  end

  test "a bucket the plug does not know is refused where it is declared" do
    assert_raise ArgumentError, ~r/:bucket must be :mcp or :api/, fn ->
      MCPRateLimit.init(bucket: :tincture)
    end
  end

  @tag :capture_log
  test "a store that cannot answer throttles by the last value read, and says so" do
    ref = :telemetry_test.attach_event_handlers(self(), [Arca.PlatformSettings.stale_event()])
    on_exit(fn -> :telemetry.detach(ref) end)

    ip = {127, 0, 0, 22}
    Settings.expire("mcp_rate_limit_max")
    Settings.expire("mcp_rate_limit_window_ms")
    Settings.break_store!()

    for _ <- 1..3, do: refute(MCPRateLimit.call(conn_from(ip), []).halted)
    assert MCPRateLimit.call(conn_from(ip), []).status == 429

    assert_received {[:cyfr, :platform_settings, :stale_served], ^ref, %{count: 1},
                     %{key: "mcp_rate_limit_max"}}
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
    Application.delete_env(:sanctum, :trust_x_forwarded_for)
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
