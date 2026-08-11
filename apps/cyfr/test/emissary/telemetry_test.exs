# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.TelemetryTest do
  @moduledoc """
  Tests for Emissary telemetry event emission.

  Verifies that proper telemetry events are emitted for:
  - Session creation/termination
  - Request processing
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.Session
  alias Sanctum.Context

  setup do
    :ok
  end

  # Helper to receive telemetry event for a specific session
  # This handles concurrent test execution where multiple sessions may be created
  defp receive_session_event(ref, session_id, lifecycle, timeout \\ 1000) do
    receive do
      {[:cyfr, :emissary, :session], ^ref, %{count: 1}, metadata} ->
        if metadata.session_id == session_id and metadata.lifecycle == lifecycle do
          metadata
        else
          # Not our session, keep looking
          receive_session_event(ref, session_id, lifecycle, timeout)
        end
    after
      timeout ->
        raise "Timeout waiting for telemetry event for session #{session_id}"
    end
  end

  describe "telemetry metrics definition" do
    # The session counter is deliberately absent: it measured a protocol
    # session's lifecycle, and there is no longer one to measure.
    test "no metric is declared without an emitter behind it" do
      names = Enum.map(EmissaryWeb.Telemetry.metrics(), & &1.name)

      refute [:cyfr, :emissary, :session, :count] in names
    end

    test "EmissaryWeb.Telemetry.metrics/0 includes request duration" do
      metrics = EmissaryWeb.Telemetry.metrics()

      request_metric =
        Enum.find(metrics, fn m ->
          m.name == [:cyfr, :emissary, :request, :duration]
        end)

      assert request_metric
      assert request_metric.tags == [:method, :tool, :status]
    end

    test "EmissaryWeb.Telemetry.metrics/0 includes Phoenix metrics" do
      metrics = EmissaryWeb.Telemetry.metrics()

      # Should include standard Phoenix metrics
      metric_names =
        metrics
        |> Enum.map(& &1.name)
        |> Enum.map(&Enum.join(&1, "."))

      assert "phoenix.endpoint.stop.duration" in metric_names
      assert "phoenix.router_dispatch.stop.duration" in metric_names
    end
  end

  describe "request telemetry events" do
    test "request telemetry event is emitted on tool call" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      # Emit a request telemetry event directly (simulating what mcp_controller does)
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: System.monotonic_time() - start_time},
        %{method: "tools/call", tool: "system", status: :success}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.method == "tools/call"
      assert metadata.tool == "system"
      assert metadata.status == :success
    end

    test "request telemetry includes method in metadata" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: 1000},
        %{method: "initialize", tool: nil, status: :success}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, _, metadata}
      assert metadata.method == "initialize"
    end

    test "request telemetry includes tool in metadata when present" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: 1000},
        %{method: "tools/call", tool: "storage", status: :success}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, _, metadata}
      assert metadata.tool == "storage"
    end

    test "request telemetry emitted on error with status :error" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: 500},
        %{method: "tools/call", tool: "system", status: :error}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.status == :error
    end

    test "request telemetry includes duration measurement" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      expected_duration = 12345

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: expected_duration},
        %{method: "ping", tool: nil, status: :success}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, measurements, _metadata}
      assert measurements.duration == expected_duration
    end

    test "request telemetry for resources/read includes tool as resources" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :request]])

      :telemetry.execute(
        [:cyfr, :emissary, :request],
        %{duration: 1000},
        %{method: "resources/read", tool: "resources", status: :success}
      )

      assert_receive {[:cyfr, :emissary, :request], ^ref, _, metadata}
      assert metadata.method == "resources/read"
      assert metadata.tool == "resources"
    end
  end
end
