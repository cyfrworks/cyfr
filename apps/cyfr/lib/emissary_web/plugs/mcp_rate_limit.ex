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

  - `:bucket` — counter namespace, default `:mcp`. Each bucket uses its own
    `:<bucket>_rate_limit_max` and `:<bucket>_rate_limit_window_ms` when set,
    otherwise it uses the shared `:mcp_rate_limit_*` budget.
  - `:errors` — rejection renderer, default `EmissaryWeb.MCPError`.
    Use `EmissaryWeb.ApiError` for routes that do not speak JSON-RPC.

  Limits are runtime config (defaults are generous — legitimate MCP clients
  make many calls in a row):

      config :cyfr, :mcp_rate_limit_max, 120
      config :cyfr, :mcp_rate_limit_window_ms, 60_000

  or `CYFR_MCP_RATE_LIMIT_MAX` / `CYFR_MCP_RATE_LIMIT_WINDOW_MS`; the `:api`
  bucket answers to `CYFR_API_RATE_LIMIT_MAX` / `CYFR_API_RATE_LIMIT_WINDOW_MS`.

  Counters live in `Prima.RateLimiter` (ETS) — single-node only, same caveat as
  `EmissaryWeb.Plugs.AuthRateLimit`.
  """

  @default_max 120
  @default_window_ms 60_000

  @default_errors EmissaryWeb.MCPError
  @default_bucket :mcp

  def init(opts) do
    bucket = Keyword.get(opts, :bucket, @default_bucket)

    opts
    |> Keyword.put_new(:errors, @default_errors)
    |> Keyword.put(:bucket, bucket)
    # Derived once at init (compile time in a router pipeline), so call/2
    # never builds atoms per request.
    |> Keyword.put(:max_key, bucket_key(bucket, "_rate_limit_max"))
    |> Keyword.put(:window_key, bucket_key(bucket, "_rate_limit_window_ms"))
  end

  def call(conn, opts) do
    bucket = Keyword.get(opts, :bucket, @default_bucket)

    max_requests =
      bucket_env(opts[:max_key]) ||
        Application.get_env(:cyfr, :mcp_rate_limit_max, @default_max)

    window_ms =
      bucket_env(opts[:window_key]) ||
        Application.get_env(:cyfr, :mcp_rate_limit_window_ms, @default_window_ms)

    ip = Sanctum.ClientIp.resolve(conn)
    key = {:rate_limit, bucket, ip}

    case Prima.RateLimiter.check(key, max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        EmissaryWeb.RateLimitRefusal.halt(
          conn,
          retry_after,
          Keyword.get(opts, :errors, @default_errors)
        )
    end
  end

  # The default bucket reads the shared keys directly — no second spelling
  # of the same knob for it.
  defp bucket_key(@default_bucket, _suffix), do: nil
  defp bucket_key(bucket, suffix), do: String.to_atom("#{bucket}#{suffix}")

  defp bucket_env(nil), do: nil
  defp bucket_env(key), do: Application.get_env(:cyfr, key)
end
