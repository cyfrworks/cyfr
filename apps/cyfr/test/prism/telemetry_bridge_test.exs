# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias Prism.TelemetryBridge

  # The bridge scopes every topic by the event's athanor, so subscribers use
  # the same scoped topic; an event that names no athanor is dropped.
  defp scoped(base), do: Sanctum.PubSub.topic(base, Sanctum.TestContext.local())

  @athanor Sanctum.TestContext.athanor_id()

  describe "handle_event/4" do
    test "broadcasts execution_started to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :start], %{duration: 100}, %{
        component: "test",
        athanor_id: @athanor
      })

      assert_receive {:execution_started, %{component: "test"}, %{duration: 100}}
    end

    test "drops an event that names no athanor" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :start], %{duration: 100}, %{
        component: "unscoped"
      })

      refute_receive {:execution_started, %{component: "unscoped"}, _}, 100
    end

    test "broadcasts execution_completed to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :stop], %{duration: 200}, %{
        component: "test",
        athanor_id: @athanor
      })

      assert_receive {:execution_completed, %{component: "test"}, %{duration: 200}}
    end

    test "broadcasts execution_failed to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:executions"))

      :telemetry.execute([:cyfr, :opus, :execute, :exception], %{duration: 50}, %{
        component: "test",
        reason: :timeout,
        athanor_id: @athanor
      })

      assert_receive {:execution_failed, %{component: "test", reason: :timeout}, %{duration: 50}}
    end

    test "broadcasts request events to subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:requests"))

      :telemetry.execute([:cyfr, :emissary, :request], %{count: 1}, %{
        method: "tools/call",
        athanor_id: @athanor
      })

      assert_receive {:request, %{method: "tools/call"}, %{count: 1}}
    end

    test "broadcasts policy decisions to enforcement subscribers" do
      Phoenix.PubSub.subscribe(Emissary.PubSub, scoped("prism:enforcement"))

      :telemetry.execute(
        [:cyfr, :sanctum, :policy, :decision],
        %{system_time: System.system_time(), duration_ms: 0},
        %{
          event_type: "rate_limit",
          decision: "denied",
          component_ref: "catalyst:local.demo",
          athanor_id: @athanor
        }
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

    test "core handlers are attached" do
      expected = [
        {[:cyfr, :opus, :execute, :start], "prism-execution_start"},
        {[:cyfr, :opus, :execute, :stop], "prism-execution_stop"},
        {[:cyfr, :opus, :execute, :exception], "prism-execution_exception"},
        {[:cyfr, :emissary, :request], "prism-request"},
        {[:cyfr, :sanctum, :policy, :decision], "prism-policy_decision"}
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
