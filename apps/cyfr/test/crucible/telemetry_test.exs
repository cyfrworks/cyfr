# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.TelemetryTest do
  use ExUnit.Case, async: false

  alias Crucible.Telemetry
  alias Crucible.Record

  setup do
    test_pid = self()

    # Attach telemetry handler for testing
    handler_id = "test-handler-#{:rand.uniform(100_000)}"

    :telemetry.attach_many(
      handler_id,
      [
        [:cyfr, :opus, :execute, :start],
        [:cyfr, :opus, :execute, :stop],
        [:cyfr, :opus, :execute, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  # ============================================================================
  # execute_start/1
  # ============================================================================

  describe "execute_start/1" do
    test "emits [:cyfr, :opus, :execute, :start] event", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test-123:0.1.0", %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], measurements, metadata}

      assert is_integer(measurements.system_time)
      assert metadata.execution_id == record.id
      assert metadata.component == "reagent:local.test-123:0.1.0"
      assert metadata.component_type == :reagent
      assert metadata.user_id == ctx.user_id
    end

    test "formats registry reference correctly", %{ctx: ctx} do
      record = Record.new(ctx, "catalyst:cyfr.calculator:1.0.0", %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "catalyst:cyfr.calculator:1.0.0"
    end

    test "formats local reference correctly", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.my-component:0.1.0", %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "reagent:local.my-component:0.1.0"
    end

    test "formats formula reference correctly", %{ctx: ctx} do
      record = Record.new(ctx, "formula:local.my-tool:1.0.0", %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "formula:local.my-tool:1.0.0"
    end

    test "includes correct component_type", %{ctx: ctx} do
      catalyst_record =
        Record.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :catalyst)

      Telemetry.execute_start(catalyst_record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component_type == :catalyst
    end
  end

  # ============================================================================
  # execute_stop/2
  # ============================================================================

  describe "execute_stop/2" do
    test "emits [:cyfr, :opus, :execute, :stop] event", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      completed = Record.complete(record, %{"result" => 42})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.outcome == :success
    end

    test "includes duration from record", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      completed = Record.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}

      # Duration should be in nanoseconds (ms * 1_000_000)
      assert measurements.duration >= 10 * 1_000_000
    end

    test "accepts memory_bytes measurement", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      completed = Record.complete(record, %{})

      Telemetry.execute_stop(completed, %{memory_bytes: 1024 * 1024})

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}
      assert measurements.memory_bytes == 1024 * 1024
    end

    test "omits memory_bytes when the runtime reports none", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      completed = Record.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}
      # Never fabricated: a zero would read as a real measurement.
      refute Map.has_key?(measurements, :memory_bytes)
    end

    test "includes all required metadata", %{ctx: ctx} do
      record =
        Record.new(ctx, "formula:local.test-456:0.1.0", %{}, component_type: :formula)

      completed = Record.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], _measurements, metadata}

      assert metadata.execution_id == record.id
      assert metadata.component == "formula:local.test-456:0.1.0"
      assert metadata.component_type == :formula
      assert metadata.user_id == ctx.user_id
      assert metadata.outcome == :success
    end
  end

  # ============================================================================
  # execute_exception/2
  # ============================================================================

  describe "execute_exception/2" do
    test "emits [:cyfr, :opus, :execute, :exception] event", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = Record.fail(record, "Something went wrong")

      Telemetry.execute_exception(failed, "Something went wrong")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], measurements,
                      metadata}

      assert is_integer(measurements.duration)
      assert metadata.outcome == :failure
      assert metadata.error == "Something went wrong"
    end

    test "includes duration from record", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      :timer.sleep(10)
      failed = Record.fail(record, "timeout")

      Telemetry.execute_exception(failed, "timeout")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], measurements,
                      _metadata}

      assert measurements.duration >= 10 * 1_000_000
    end

    test "renders a non-string error through the table", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})
      failed = Record.fail(record, "error")

      Telemetry.execute_exception(failed, {:badmatch, :unexpected})

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], _measurements,
                      metadata}

      # Rendered through the table: an unknown term reads as the fixed
      # sentence, never its spelling.
      assert metadata.error == Prima.Refusal.unconfirmed()
    end

    test "includes all required metadata", %{ctx: ctx} do
      record =
        Record.new(ctx, "catalyst:cyfr.myapp:2.0.0", %{}, component_type: :catalyst)

      failed = Record.fail(record, "Network timeout")

      Telemetry.execute_exception(failed, "Network timeout")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], _measurements,
                      metadata}

      assert metadata.execution_id == record.id
      assert metadata.component == "catalyst:cyfr.myapp:2.0.0"
      assert metadata.component_type == :catalyst
      assert metadata.user_id == ctx.user_id
      assert metadata.outcome == :failure
      assert metadata.error == "Network timeout"
    end
  end

  # ============================================================================
  # row_failed/3
  # ============================================================================

  describe "row_failed/3" do
    defp row(component_type) do
      %{
        id: "exec_row_failed",
        request_id: "req_row_failed",
        reference: "formula:local.parent:1.0.0",
        component_type: component_type,
        user_id: "user_row_failed",
        athanor_id: "ath_row_failed"
      }
    end

    test "reports a row failed from outside with its stored type as an atom" do
      Telemetry.row_failed(row("formula"), "Parent execution (exec_p) terminated", 12)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], measurements,
                      metadata}

      assert measurements.duration == 12 * 1_000_000
      assert is_integer(measurements.system_time)

      assert metadata == %{
               execution_id: "exec_row_failed",
               request_id: "req_row_failed",
               component: "formula:local.parent:1.0.0",
               reference: "formula:local.parent:1.0.0",
               component_type: :formula,
               user_id: "user_row_failed",
               athanor_id: "ath_row_failed",
               outcome: :failure,
               error: "Parent execution (exec_p) terminated",
               duration_ms: 12
             }
    end

    test "reports a type that names no executable type as a reagent" do
      for type <- ["agent", nil, "tincture"] do
        Telemetry.row_failed(row(type), "Execution terminated", 0)

        assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], _,
                        %{component_type: :reagent}}
      end
    end
  end

  # ============================================================================
  # Event Ordering
  # ============================================================================

  describe "event ordering" do
    test "start event precedes stop event in typical flow", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      Telemetry.execute_start(record)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _start_measurements, _}

      :timer.sleep(5)
      completed = Record.complete(record, %{})
      Telemetry.execute_stop(completed)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], stop_measurements, _}

      # Stop duration should be greater than time between events
      assert stop_measurements.duration > 0
    end

    test "start event precedes exception event in error flow", %{ctx: ctx} do
      record = Record.new(ctx, "reagent:local.test:0.1.0", %{})

      Telemetry.execute_start(record)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _, _}

      :timer.sleep(5)
      failed = Record.fail(record, "error")
      Telemetry.execute_exception(failed, "error")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception],
                      exception_measurements, _}

      assert exception_measurements.duration > 0
    end
  end
end
