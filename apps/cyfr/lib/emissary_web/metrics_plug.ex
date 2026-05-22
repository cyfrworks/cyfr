# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MetricsPlug do
  @moduledoc """
  Plug that exposes Prometheus metrics at `/metrics`.

  This endpoint is unauthenticated by design — bind Emissary to a private
  interface or use a reverse-proxy allowlist in production.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/metrics", method: "GET"} = conn, _opts) do
    if Application.get_env(:cyfr, :prometheus_metrics_enabled, true) do
      metrics = TelemetryMetricsPrometheus.Core.scrape(:cyfr_prometheus)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, metrics)
      |> halt()
    else
      conn
      |> send_resp(404, "Metrics disabled")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn
end