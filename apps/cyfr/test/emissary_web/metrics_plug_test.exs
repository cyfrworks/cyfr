# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MetricsPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias EmissaryWeb.MetricsPlug

  test "returns 404 when metrics are disabled (the default)" do
    conn = conn(:get, "/metrics") |> MetricsPlug.call([])

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == "Metrics disabled"
  end

  test "serves the Prometheus scrape when enabled" do
    # Under the disabled default the app never starts the Core reporter, so
    # the enabled path has to bring its own.
    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [], name: :cyfr_prometheus})

    previous = Application.get_env(:cyfr, :prometheus_metrics_enabled, false)
    Application.put_env(:cyfr, :prometheus_metrics_enabled, true)
    on_exit(fn -> Application.put_env(:cyfr, :prometheus_metrics_enabled, previous) end)

    conn = conn(:get, "/metrics") |> MetricsPlug.call([])

    assert conn.status == 200
    assert conn.halted
    assert {"content-type", "text/plain; charset=utf-8"} in conn.resp_headers
  end

  test "passes through non-metrics requests untouched" do
    conn = conn(:get, "/api/health")

    assert MetricsPlug.call(conn, []) == conn
  end
end
