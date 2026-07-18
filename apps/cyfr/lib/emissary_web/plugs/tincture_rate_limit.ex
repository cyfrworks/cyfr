# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.TinctureRateLimit do
  @moduledoc """
  Transport-level rate limiting for the public tincture surface.

  Keys buckets per (bucket, client IP, publisher, tincture_name) so one hot
  dashboard can't starve another and one hostile IP can't exhaust a shared
  budget. The IP comes from `Sanctum.ClientIp.resolve/1`, honoring the same
  X-Forwarded-For trust boundary as the other limiters. Configured per
  pipeline via `init/1` opts:

      plug EmissaryWeb.Plugs.TinctureRateLimit,
        bucket: :page,
        max_requests: 60,
        window_ms: 60_000

  Routes without tincture path params (e.g. `/t/access-token`) key as
  `{"unknown", "unknown"}`, making their limit effectively per-IP.

  This is a transport back-stop under the policy-level limit: a tincture
  policy's `rate_limit` (when configured) throttles invokes per
  tenant+component via `Opus.RateLimiter`, while this plug always bounds
  per-IP request volume — including for tinctures with no policy limit.

  Counters live in `Arca.Cache` (ETS) so the plug is single-node only; the
  off-by-one on concurrent boundary requests is acceptable for rate limits
  (not a security boundary).

  `config :cyfr, :tincture_rate_limit_max` overrides `max_requests` when set
  (used by the test env so unrelated controller suites don't trip the limit).
  """

  import Plug.Conn

  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      max_requests: Keyword.fetch!(opts, :max_requests),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }
  end

  def call(conn, %{bucket: bucket, max_requests: default_max, window_ms: window_ms}) do
    max_requests = Application.get_env(:cyfr, :tincture_rate_limit_max) || default_max
    ip = Sanctum.ClientIp.resolve(conn)

    {publisher, tincture_name} =
      case {conn.path_params["publisher"], conn.path_params["tincture_name"]} do
        {pub, name} when is_binary(pub) and is_binary(name) ->
          {pub, name}

        _ ->
          # Tincture paths are /t/:org/:project/:publisher/:tincture_name[/...].
          case conn.path_info do
            ["t", _org, _project, pub, name | _] -> {pub, name}
            _ -> {"unknown", "unknown"}
          end
      end

    key = {:rate_limit, bucket, ip, publisher, tincture_name}
    now = System.monotonic_time(:millisecond)

    # Non-atomic read-check-write — two concurrent requests at the limit
    # boundary could both pass. Acceptable for rate limiting (off-by-one,
    # not a security boundary).
    case Arca.Cache.get(key) do
      {:ok, {count, window_start}} when now - window_start < window_ms ->
        if count >= max_requests do
          remaining_ms = window_ms - (now - window_start)
          retry_after = max(div(remaining_ms, 1000), 1)

          conn
          |> put_resp_header("retry-after", to_string(retry_after))
          |> send_resp(429, "Rate limit exceeded. Try again in #{retry_after} seconds.")
          |> halt()
        else
          Arca.Cache.put(key, {count + 1, window_start}, window_ms)
          conn
        end

      _ ->
        Arca.Cache.put(key, {1, now}, window_ms)
        conn
    end
  end
end
