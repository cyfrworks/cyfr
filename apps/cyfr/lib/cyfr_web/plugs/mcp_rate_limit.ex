# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.MCPRateLimit do
  @moduledoc """
  Transport-level, per-IP rate limiting.

  Runs before `CyfrWeb.Plugs.Authenticate` so unauthenticated floods are
  dropped before touching DB state. Keyed by `Sanctum.ClientIp.resolve/1` so
  the key honors the same X-Forwarded-For trust boundary as the API-key
  allowlist. Long-lived SSE streams count once at connection establishment; the
  open stream itself is not throttled.

  On breach, replies 429 with a `retry-after` header.

  ## Options

  - `:bucket` — counter namespace, `:mcp` (the default) or `:api`. Each
    bucket reads its own `<bucket>_rate_limit_max` and
    `<bucket>_rate_limit_window_ms` platform settings; the `:api` pair,
    unset, is the MCP pair's value.
  - `:errors` — rejection renderer, default `CyfrWeb.ApiError`. A JSON-RPC
    route passes its own renderer.

  The limits are platform settings, read on each request through
  `Arca.PlatformSettings.effective/1` (defaults are generous — legitimate
  MCP clients make many calls in a row: 120 requests a minute), pinned by
  `CYFR_MCP_RATE_LIMIT_MAX` / `CYFR_MCP_RATE_LIMIT_WINDOW_MS` and
  `CYFR_API_RATE_LIMIT_MAX` / `CYFR_API_RATE_LIMIT_WINDOW_MS`. They serve a
  stale value, so a store that cannot answer throttles by the last value
  read and refuses no one for it.

  Counters live in `Prima.RateLimiter` (ETS) — per member, same caveat as
  `CyfrWeb.Plugs.AuthRateLimit`.
  """

  @default_errors CyfrWeb.ApiError
  @default_bucket :mcp
  @buckets [:mcp, :api]

  def init(opts) do
    bucket = Keyword.get(opts, :bucket, @default_bucket)

    unless bucket in @buckets do
      raise ArgumentError, "CyfrWeb.Plugs.MCPRateLimit: :bucket must be :mcp or :api"
    end

    opts
    |> Keyword.put_new(:errors, @default_errors)
    |> Keyword.put(:bucket, bucket)
  end

  def call(conn, opts) do
    bucket = Keyword.get(opts, :bucket, @default_bucket)
    max_requests = limit(bucket, "_rate_limit_max")
    window_ms = limit(bucket, "_rate_limit_window_ms")

    ip = Sanctum.ClientIp.resolve(conn)
    key = {:rate_limit, bucket, ip}

    case Prima.RateLimiter.check(key, max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        CyfrWeb.RateLimitRefusal.halt(
          conn,
          retry_after,
          Keyword.get(opts, :errors, @default_errors)
        )
    end
  end

  # The bucket's own setting, else (the `:api` pair, unset) the MCP pair's.
  # Both serve a stale value, so a store outage answers the last one read.
  defp limit(bucket, suffix) do
    case setting("#{bucket}#{suffix}") do
      nil -> setting("#{@default_bucket}#{suffix}")
      value -> value
    end
  end

  defp setting(key) do
    {:ok, value} = Arca.PlatformSettings.effective(key)
    value
  end
end
