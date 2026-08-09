# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.AuthRateLimit do
  @moduledoc """
  In-process rate limiting for pre-session auth routes.

  Used on endpoints that don't yet have a resolved session — username
  enumeration / OAuth kickoff — keyed by client IP. The IP comes from
  `Sanctum.ClientIp.resolve/1`, honoring the same X-Forwarded-For trust
  boundary as `MCPRateLimit` — behind a trusted proxy each real client
  gets its own bucket instead of all sharing the proxy's. Configured per
  call site via `init/1` opts:

      plug EmissaryWeb.Plugs.AuthRateLimit,
        bucket: :claim_submit,
        max_requests: 10,
        window_ms: 60_000

  Counters live in `Cyfr.RateLimiter` (ETS) so the plug is single-node only; the
  off-by-one on concurrent boundary requests is acceptable for rate limits
  (not a security boundary). For multi-node deployments the counter needs
  a shared store, out of scope here.

  Returns 429 with `retry-after` on breach. Shares the pattern of the
  tincture-side `EmissaryWeb.Plugs.TinctureRateLimit`; kept separate because
  the key topology (IP-only vs. IP+publisher+tincture) differs.
  """

  import Plug.Conn

  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    max_requests = Keyword.fetch!(opts, :max_requests)
    window_ms = Keyword.fetch!(opts, :window_ms)

    %{bucket: bucket, max_requests: max_requests, window_ms: window_ms}
  end

  def call(conn, %{bucket: bucket, max_requests: max_requests, window_ms: window_ms}) do
    ip = Sanctum.ClientIp.resolve(conn)
    key = {:rate_limit, bucket, ip}

    case Cyfr.RateLimiter.check(key, max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> send_resp(429, "Rate limit exceeded. Try again in #{retry_after} seconds.")
        |> halt()
    end
  end
end
