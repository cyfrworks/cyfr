defmodule Arca.AuditHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    original_sinks = Application.get_env(:cyfr, :audit_sinks)

    on_exit(fn ->
      if original_sinks,
        do: Application.put_env(:cyfr, :audit_sinks, original_sinks),
        else: Application.delete_env(:cyfr, :audit_sinks)
    end)

    :ok
  end

  describe "handle_event/4" do
    test "dispatches to configured sinks" do
      test_pid = self()

      defmodule TestSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(event_name, measurements, metadata) do
          send(metadata[:test_pid], {:audit, event_name, measurements})
          :ok
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [TestSink])

      Arca.AuditHandler.handle_event(
        [:cyfr, :sanctum, :auth],
        %{count: 1},
        %{test_pid: test_pid, user_id: "u1"},
        nil
      )

      assert_receive {:audit, [:cyfr, :sanctum, :auth], %{count: 1}}
    end

    test "error isolation — one sink fails, others still called" do
      test_pid = self()

      defmodule FailingSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(_event_name, _measurements, _metadata) do
          raise "boom"
        end
      end

      defmodule GoodSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(event_name, _measurements, metadata) do
          send(metadata[:test_pid], {:good_sink, event_name})
          :ok
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [FailingSink, GoodSink])

      log =
        capture_log(fn ->
          Arca.AuditHandler.handle_event(
            [:cyfr, :sanctum, :auth],
            %{count: 1},
            %{test_pid: test_pid, user_id: "u1"},
            nil
          )
        end)

      assert_receive {:good_sink, [:cyfr, :sanctum, :auth]}
      assert log =~ "FailingSink"
      assert log =~ "failed"
    end

    test "injects context into metadata when missing" do
      test_pid = self()

      defmodule ContextCheckSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(_event_name, _measurements, metadata) do
          send(metadata[:test_pid], {:context, metadata[:context]})
          :ok
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [ContextCheckSink])

      Arca.AuditHandler.handle_event(
        [:cyfr, :sanctum, :auth],
        %{count: 1},
        %{test_pid: test_pid, user_id: "test_user"},
        nil
      )

      assert_receive {:context, %Sanctum.Context{user_id: "test_user"}}
    end

    test "emits pipeline_failure telemetry when all sinks fail" do
      test_pid = self()

      :telemetry.attach(
        "test-pipeline-failure",
        [:cyfr, :audit, :pipeline_failure],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:pipeline_failure, event, measurements, metadata})
        end,
        nil
      )

      defmodule AllFailSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(_event_name, _measurements, _metadata) do
          raise "total failure"
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [AllFailSink])

      capture_log(fn ->
        Arca.AuditHandler.handle_event(
          [:cyfr, :sanctum, :auth],
          %{count: 1},
          %{user_id: "u1"},
          nil
        )
      end)

      assert_receive {:pipeline_failure, [:cyfr, :audit, :pipeline_failure], %{count: 1},
                      %{event: [:cyfr, :sanctum, :auth]}}

      :telemetry.detach("test-pipeline-failure")
    end
  end
end
