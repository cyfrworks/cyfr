# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias Prism.TelemetryBridge

  # The bridge tenant-scopes every topic (org-less telemetry defaults to the
  # seeded local/default workspace), so subscribers use the same scoped topic.
  defp scoped(base), do: Sanctum.PubSub.topic(base, Sanctum.TestContext.local())

  describe "handle_event/4" do
    test "broadcasts execution_started to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :start], %{duration: 100}, %{
        component: "test"
      })

      assert_receive {:execution_started, %{component: "test"}, %{duration: 100}}
    end

    test "broadcasts execution_completed to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :stop], %{duration: 200}, %{
        component: "test"
      })

      assert_receive {:execution_completed, %{component: "test"}, %{duration: 200}}
    end

    test "broadcasts execution_failed to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :exception], %{duration: 50}, %{
        component: "test",
        reason: :timeout
      })

      assert_receive {:execution_failed, %{component: "test", reason: :timeout}, %{duration: 50}}
    end

    test "broadcasts request events to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:requests"))

      :telemetry.execute([:cyfr, :emissary, :request], %{count: 1}, %{method: "tools/call"})

      assert_receive {:request, %{method: "tools/call"}, %{count: 1}}
    end

    test "broadcasts auth events to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:system"))

      :telemetry.execute([:cyfr, :sanctum, :auth], %{count: 1}, %{user: "test"})

      assert_receive {:auth_event, %{user: "test"}, %{count: 1}}
    end

    test "broadcasts policy events to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:components"))

      :telemetry.execute([:cyfr, :sanctum, :policy], %{count: 1}, %{action: "update"})

      assert_receive {:policy_changed, %{action: "update"}, %{count: 1}}
    end

    test "broadcasts policy decisions to enforcement subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:enforcement"))

      :telemetry.execute(
        [:cyfr, :sanctum, :policy, :decision],
        %{system_time: System.system_time(), duration_ms: 0},
        %{event_type: "rate_limit", decision: "denied", component_ref: "catalyst:local.demo"}
      )

      assert_receive {:policy_decision, %{event_type: "rate_limit", decision: "denied"}, _meas}
    end

    test "catch-all returns :ok" do
      assert :ok = TelemetryBridge.handle_event([:unknown], %{}, %{}, nil)
    end
  end

  describe "handler resilience" do
    test "handler is not detached after broadcast" do
      # Fire event — safe_broadcast prevents detachment even if PubSub errors
      :telemetry.execute([:cyfr, :opus, :execute, :start], %{}, %{})

      handlers = :telemetry.list_handlers([:cyfr, :opus, :execute, :start])

      assert Enum.any?(handlers, fn %{id: id} ->
               id == "prism-execution_start"
             end)
    end

    test "all 6 handlers are attached" do
      expected = [
        {[:cyfr, :opus, :execute, :start], "prism-execution_start"},
        {[:cyfr, :opus, :execute, :stop], "prism-execution_stop"},
        {[:cyfr, :opus, :execute, :exception], "prism-execution_exception"},
        {[:cyfr, :emissary, :request], "prism-request"},
        {[:cyfr, :sanctum, :auth], "prism-auth"},
        {[:cyfr, :sanctum, :policy], "prism-policy"}
      ]

      for {event, handler_id} <- expected do
        handlers = :telemetry.list_handlers(event)

        assert Enum.any?(handlers, fn %{id: id} -> id == handler_id end),
               "Handler #{handler_id} not found for event #{inspect(event)}"
      end
    end
  end

  describe "handle_info/2" do
    test "handles unexpected messages gracefully" do
      state = %{}
      assert {:noreply, ^state} = TelemetryBridge.handle_info(:unexpected, state)
    end
  end
end
