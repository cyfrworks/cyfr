# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPRateLimit do
  @moduledoc """
  Transport-level, per-IP rate limiting.

  Runs before `EmissaryWeb.Plugs.Authenticate` so unauthenticated floods are
  dropped before touching DB state. Keyed by `Sanctum.ClientIp.resolve/1` so
  the key honors the same X-Forwarded-For trust boundary as the API-key
  allowlist. Long-lived SSE streams count once at connection establishment; the
  open stream itself is not throttled.

  On breach, replies 429 with a `retry-after` header.

  ## Options

  - `:bucket` — the counter namespace, defaulting to `:mcp`. Routes with
    different traffic shapes get their own: a page reconnecting to an event
    stream should not spend the budget its MCP calls need.
  - `:errors` — the module that renders a rejection, defaulting to
    `EmissaryWeb.MCPError`. Use `EmissaryWeb.ApiError` on a route that does not
    speak JSON-RPC.

  Limits are runtime config (defaults are generous — legitimate MCP clients
  make many calls in a row):

      config :cyfr, :mcp_rate_limit_max, 120
      config :cyfr, :mcp_rate_limit_window_ms, 60_000

  or `CYFR_MCP_RATE_LIMIT_MAX` / `CYFR_MCP_RATE_LIMIT_WINDOW_MS`.

  Counters live in `Cyfr.RateLimiter` (ETS) — single-node only, same caveat as
  `EmissaryWeb.Plugs.AuthRateLimit`.
  """

  import Plug.Conn

  @default_max 120
  @default_window_ms 60_000

  @default_errors EmissaryWeb.MCPError
  @default_bucket :mcp

  def init(opts) do
    opts
    |> Keyword.put_new(:errors, @default_errors)
    |> Keyword.put_new(:bucket, @default_bucket)
  end

  def call(conn, opts) do
    max_requests = Application.get_env(:cyfr, :mcp_rate_limit_max, @default_max)
    window_ms = Application.get_env(:cyfr, :mcp_rate_limit_window_ms, @default_window_ms)

    ip = Sanctum.ClientIp.resolve(conn)
    key = {:rate_limit, Keyword.get(opts, :bucket, @default_bucket), ip}

    case Cyfr.RateLimiter.check(key, max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> Keyword.get(opts, :errors, @default_errors).halt(
          429,
          :rate_limited,
          "Rate limit exceeded. Try again in #{retry_after} seconds."
        )
    end
  end
end
