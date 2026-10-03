# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.TinctureRateLimit do
  @moduledoc """
  Transport-level rate limiting for the public tincture surface.

  Keys buckets per (bucket, client IP, athanor, publisher, tincture_name)
  so one hot dashboard can't starve another, one hostile IP can't exhaust
  a shared budget, and two athanors hosting the same publisher/name never
  share a counter — without the athanor segment, tenant A's traffic
  throttled tenant B's identically-named tincture. The IP comes from
  `Sanctum.ClientIp.resolve/1`, honoring the same X-Forwarded-For trust
  boundary as the other limiters. Configured per pipeline via `init/1`
  opts:

      plug CyfrWeb.Plugs.TinctureRateLimit,
        bucket: :page,
        max_requests: 60,
        window_ms: 60_000

  A private tincture version's files (`/_s/<credential>/…`) key per asset
  credential instead: the credential is the whole of what such a request
  presents, so one person's version window is one budget whatever address
  it is fetched from. The key holds the credential's SHA-256, never the
  credential. Routes without tincture path params (the tincture data
  routes, `/_f/v1/*`) key as `{"unknown", "unknown", "unknown"}`, making
  their limit effectively per-IP — a transport back-stop under the
  per-frame limits the data routes hold themselves.

  `:errors` names the `CyfrWeb.ErrorRenderer` a refusal is rendered with
  (`CyfrWeb.ApiError` unless the pipeline speaks another wire).

  This is a transport back-stop under the policy-level limit: a tincture
  policy's `rate_limit` (when configured) throttles invokes per
  tenant+component via `Crucible.Rates`, while this plug always bounds
  per-IP request volume — including for tinctures with no policy limit.

  Counters live in `Prima.RateLimiter` (ETS) so the plug is single-node only; the
  off-by-concurrency overshoot on boundary requests (N concurrent readers
  can each pass the cap check) is acceptable for rate limits (not a
  security boundary).

  `config :cyfr, :tincture_rate_limit_max` overrides `max_requests` when set
  (used by the test env so unrelated controller suites don't trip the limit).
  """

  # The invoke budget both surfaces share lives in Cyfr.RuntimeConfig —
  # glue both the transport plug and the console may name (the console
  # naming THIS plug was the one console→transport back-edge). The HTTP
  # pipeline keys it by IP through this plug; the console shell keys the
  # same budget by person — deliberately separate buckets, one number.
  @asset_prefix Prima.TinctureUrl.asset_prefix()

  @doc "The default per-window invoke budget (both ingress surfaces)."
  defdelegate default_invoke_max, to: Cyfr.RuntimeConfig, as: :tincture_default_invoke_max

  @doc """
  The effective invoke budget: the operator's override if set, else the
  default above.

  One reader for the override. `PrismWeb.ShellLive` spelled the same
  `Application.get_env(:cyfr, :tincture_rate_limit_max) || …` itself, so the
  key had two readers and the two could disagree about what "unset" means.
  """
  @spec invoke_max() :: pos_integer()
  defdelegate invoke_max, to: Cyfr.RuntimeConfig, as: :tincture_invoke_max

  @doc "The rate window (ms) both ingress surfaces share."
  defdelegate default_window_ms, to: Cyfr.RuntimeConfig, as: :tincture_rate_window_ms

  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      max_requests: Keyword.fetch!(opts, :max_requests),
      window_ms: Keyword.fetch!(opts, :window_ms),
      errors: Keyword.get(opts, :errors, CyfrWeb.ApiError)
    }
  end

  def call(conn, %{bucket: bucket, max_requests: default_max, window_ms: window_ms} = opts) do
    max_requests = Application.get_env(:cyfr, :tincture_rate_limit_max) || default_max

    case Prima.RateLimiter.check(key(conn, bucket), max_requests, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        CyfrWeb.RateLimitRefusal.halt(conn, retry_after, Map.get(opts, :errors, CyfrWeb.ApiError))
    end
  end

  # A served private file is its asset credential's; everything else is
  # its address's, per tincture where the path names one.
  defp key(%Plug.Conn{path_info: [@asset_prefix, credential | _]}, bucket)
       when is_binary(credential) do
    {:rate_limit, bucket, :asset_credential, :crypto.hash(:sha256, credential)}
  end

  defp key(conn, bucket) do
    ip = Sanctum.ClientIp.resolve(conn)

    {athanor, publisher, tincture_name} =
      case {conn.path_params["athanor"], conn.path_params["publisher"],
            conn.path_params["tincture_name"]} do
        {ath, pub, name} when is_binary(ath) and is_binary(pub) and is_binary(name) ->
          {ath, pub, name}

        _ ->
          # Tincture paths are /t/:athanor/:publisher/:tincture_name[/...].
          case conn.path_info do
            ["t", ath, pub, name | _] -> {ath, pub, name}
            _ -> {"unknown", "unknown", "unknown"}
          end
      end

    {:rate_limit, bucket, ip, athanor, publisher, tincture_name}
  end
end
