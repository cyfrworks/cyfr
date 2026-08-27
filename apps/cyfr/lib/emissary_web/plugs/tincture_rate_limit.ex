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

  Counters live in `Cyfr.RateLimiter` (ETS) so the plug is single-node only; the
  off-by-one on concurrent boundary requests is acceptable for rate limits
  (not a security boundary).

  `config :cyfr, :tincture_rate_limit_max` overrides `max_requests` when set
  (used by the test env so unrelated controller suites don't trip the limit).
  """

  import Plug.Conn

  # The invoke budget both surfaces share as their DEFAULT (config override:
  # :tincture_rate_limit_max). The HTTP pipeline keys it by IP through this
  # plug; the console shell keys the same budget by person — deliberately
  # separate buckets, one number.
  @default_invoke_max 120

  @doc "The default per-window invoke budget (both ingress surfaces)."
  def default_invoke_max, do: @default_invoke_max

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
          # Tincture paths are /t/:athanor/:publisher/:tincture_name[/...].
          case conn.path_info do
            ["t", _athanor, pub, name | _] -> {pub, name}
            _ -> {"unknown", "unknown"}
          end
      end

    key = {:rate_limit, bucket, ip, publisher, tincture_name}

    case Cyfr.RateLimiter.check(key, max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> EmissaryWeb.ApiError.halt(
          429,
          :rate_limited,
          "Rate limit exceeded. Try again in #{retry_after} seconds."
        )
    end
  end
end
