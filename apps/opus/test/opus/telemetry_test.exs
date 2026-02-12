defmodule Opus.TelemetryTest do
  use ExUnit.Case, async: false

  alias Opus.Telemetry
  alias Opus.ExecutionRecord
  alias Sanctum.Context

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

    ctx = Context.local()
    {:ok, ctx: ctx}
  end

  # ============================================================================
  # execute_start/1
  # ============================================================================

  describe "execute_start/1" do
    test "emits [:cyfr, :opus, :execute, :start] event", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test-123.wasm"}, %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], measurements, metadata}

      assert is_integer(measurements.system_time)
      assert metadata.execution_id == record.id
      assert metadata.component == "local:test-123.wasm"
      assert metadata.component_type == :reagent
      assert metadata.user_id == ctx.user_id
    end

    test "formats OCI reference correctly", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"oci" => "registry.cyfr.run/tool:1.0"}, %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "registry.cyfr.run/tool:1.0"
    end

    test "formats local reference correctly", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "/path/to/my-component.wasm"}, %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "local:my-component.wasm"
    end

    test "formats arca reference correctly", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"arca" => "artifacts/my-tool.wasm"}, %{})

      Telemetry.execute_start(record)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _measurements, metadata}
      assert metadata.component == "arca:artifacts/my-tool.wasm"
    end

    test "includes correct component_type", %{ctx: ctx} do
      catalyst_record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{}, component_type: :catalyst)
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
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      completed = ExecutionRecord.complete(record, %{"result" => 42})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert is_integer(measurements.memory_bytes)
      assert metadata.outcome == :success
    end

    test "includes duration from record", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      :timer.sleep(10)
      completed = ExecutionRecord.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}

      # Duration should be in nanoseconds (ms * 1_000_000)
      assert measurements.duration >= 10 * 1_000_000
    end

    test "accepts memory_bytes measurement", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      completed = ExecutionRecord.complete(record, %{})

      Telemetry.execute_stop(completed, %{memory_bytes: 1024 * 1024})

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}
      assert measurements.memory_bytes == 1024 * 1024
    end

    test "defaults memory_bytes to 0", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      completed = ExecutionRecord.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], measurements, _metadata}
      assert measurements.memory_bytes == 0
    end

    test "includes all required metadata", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test-456.wasm"}, %{}, component_type: :formula)
      completed = ExecutionRecord.complete(record, %{})

      Telemetry.execute_stop(completed)

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], _measurements, metadata}

      assert metadata.execution_id == record.id
      assert metadata.component == "local:test-456.wasm"
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
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      failed = ExecutionRecord.fail(record, "Something went wrong")

      Telemetry.execute_exception(failed, "Something went wrong")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.outcome == :failure
      assert metadata.error == "Something went wrong"
    end

    test "includes duration from record", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      :timer.sleep(10)
      failed = ExecutionRecord.fail(record, "timeout")

      Telemetry.execute_exception(failed, "timeout")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], measurements, _metadata}
      assert measurements.duration >= 10 * 1_000_000
    end

    test "formats non-string errors", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})
      failed = ExecutionRecord.fail(record, "error")

      Telemetry.execute_exception(failed, {:badmatch, :unexpected})

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], _measurements, metadata}
      assert metadata.error == "{:badmatch, :unexpected}"
    end

    test "includes all required metadata", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"oci" => "registry.example.com/app:2.0"}, %{}, component_type: :catalyst)
      failed = ExecutionRecord.fail(record, "Network timeout")

      Telemetry.execute_exception(failed, "Network timeout")

      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], _measurements, metadata}

      assert metadata.execution_id == record.id
      assert metadata.component == "registry.example.com/app:2.0"
      assert metadata.component_type == :catalyst
      assert metadata.user_id == ctx.user_id
      assert metadata.outcome == :failure
      assert metadata.error == "Network timeout"
    end
  end

  # ============================================================================
  # Event Ordering
  # ============================================================================

  describe "event ordering" do
    test "start event precedes stop event in typical flow", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})

      Telemetry.execute_start(record)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], start_measurements, _}

      :timer.sleep(5)
      completed = ExecutionRecord.complete(record, %{})
      Telemetry.execute_stop(completed)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :stop], stop_measurements, _}

      # Stop duration should be greater than time between events
      assert stop_measurements.duration > 0
    end

    test "start event precedes exception event in error flow", %{ctx: ctx} do
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{})

      Telemetry.execute_start(record)
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :start], _, _}

      :timer.sleep(5)
      failed = ExecutionRecord.fail(record, "error")
      Telemetry.execute_exception(failed, "error")
      assert_receive {:telemetry_event, [:cyfr, :opus, :execute, :exception], exception_measurements, _}

      assert exception_measurements.duration > 0
    end
  end
end
