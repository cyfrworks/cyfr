# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MetricsPlug do
  @moduledoc """
  Plug that exposes Prometheus metrics at `/metrics`.

  Disabled by default (`CYFR_PROMETHEUS_METRICS=true` opts in). With
  `CYFR_METRICS_TOKEN` set, the scrape requires `Authorization: Bearer
  <token>` — Prometheus speaks that natively (`authorization:` in the
  scrape config). Without a token the endpoint stays unauthenticated when
  enabled: bind Emissary to a private interface or use a reverse-proxy
  allowlist in production. The exposed series carry per-route and per-tool
  tags — a fair map of the deployment, worth gating.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/metrics", method: "GET"} = conn, _opts) do
    cond do
      not Cyfr.RuntimeConfig.prometheus_metrics_enabled?() ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Metrics disabled")
        |> halt()

      not authorized?(conn) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Unauthorized")
        |> halt()

      true ->
        metrics = TelemetryMetricsPrometheus.Core.scrape(:cyfr_prometheus)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, metrics)
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  # No configured token means the operator chose network-level protection;
  # a configured one is compared constant-time like every other bearer.
  defp authorized?(conn) do
    case Application.get_env(:cyfr, :metrics_token) do
      nil ->
        true

      token when is_binary(token) ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
          _ -> false
        end
    end
  end
end
