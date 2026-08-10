# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPRateLimit do
  @moduledoc """
  Transport-level rate limiting for the MCP endpoint.

  Runs before `MCPSession` so unauthenticated floods (initialize spam,
  SSE connection churn) are dropped before touching session or DB state.
  Keyed by `Sanctum.ClientIp.resolve/1` so the key honors the same
  X-Forwarded-For trust boundary as the API-key allowlist. Long-lived SSE
  streams count once at connection establishment; the open stream itself
  is not throttled.

  On breach, replies with a JSON-RPC-shaped 429 (`rate_limited` CYFR code)
  plus a `retry-after` header, since MCP clients expect JSON-RPC bodies.

  Limits are runtime config (defaults are generous — legitimate MCP clients
  make many calls per session):

      config :cyfr, :mcp_rate_limit_max, 120
      config :cyfr, :mcp_rate_limit_window_ms, 60_000

  or `CYFR_MCP_RATE_LIMIT_MAX` / `CYFR_MCP_RATE_LIMIT_WINDOW_MS`.

  Counters live in `Cyfr.RateLimiter` (ETS) — single-node only, same caveat as
  `EmissaryWeb.Plugs.AuthRateLimit`.
  """

  import Plug.Conn

  @default_max 120
  @default_window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    max_requests = Application.get_env(:cyfr, :mcp_rate_limit_max, @default_max)
    window_ms = Application.get_env(:cyfr, :mcp_rate_limit_window_ms, @default_window_ms)

    ip = Sanctum.ClientIp.resolve(conn)
    key = {:rate_limit, :mcp, ip}

    case Cyfr.RateLimiter.check(key, max_requests, window_ms) do
      :ok -> conn
      {:deny, retry_after} -> reject(conn, retry_after)
    end
  end

  defp reject(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> EmissaryWeb.MCPError.halt(
      429,
      :rate_limited,
      "Rate limit exceeded. Try again in #{retry_after} seconds."
    )
  end
end
