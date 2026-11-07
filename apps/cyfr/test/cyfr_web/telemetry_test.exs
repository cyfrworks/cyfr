# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.TelemetryTest do
  @moduledoc """
  The console reporter development runs prints each event's metadata
  through the redaction vocabulary every log shares (`Prima.Sanitizer`):
  the endpoint's and LiveView's events carry the session, and the
  person's session token with it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Telemetry.Metrics, only: [counter: 2]

  @event [:cyfr_web_test, :console]

  # The children the console setting adds, as `CyfrWeb.Telemetry` starts them.
  defp console_children do
    children = fn enabled ->
      Prima.Test.Env.with_app_env(:cyfr, :telemetry_console_enabled, enabled, fn ->
        {:ok, {_flags, children}} = CyfrWeb.Telemetry.init([])
        children
      end)
    end

    children.(true) -- children.(false)
  end

  test "the console prints an event's session with its token redacted" do
    [%{start: {reporter, :start_link, [opts]}}] = console_children()

    # This event alone, so no other test's events print meanwhile.
    metrics = [counter("cyfr_web_test.console.count", event_name: @event)]

    start_supervised!(%{
      id: :console,
      start: {reporter, :start_link, [Keyword.put(opts, :metrics, metrics)]}
    })

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    printed =
      capture_io(fn ->
        :telemetry.execute(@event, %{count: 1}, %{
          session: %{"sanctum_session_token" => token, "surface" => "chat"}
        })
      end)

    assert printed =~ "Event name: cyfr_web_test.console"
    assert printed =~ ~s("sanctum_session_token" => "[REDACTED]")
    assert printed =~ ~s("surface" => "chat")
    refute printed =~ token
  end
end
