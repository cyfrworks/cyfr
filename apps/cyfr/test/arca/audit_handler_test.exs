# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
        def handle_audit_event(%Arca.Audit.Event{} = event) do
          send(event.metadata[:test_pid], {:audit, event.name, event.measurements})
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
        def handle_audit_event(_event) do
          raise "boom"
        end
      end

      defmodule GoodSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(%Arca.Audit.Event{} = event) do
          send(event.metadata[:test_pid], {:good_sink, event.name})
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

    test "sanitizes metadata and constructs no context" do
      test_pid = self()

      defmodule StructCheckSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(%Arca.Audit.Event{} = event) do
          send(event.metadata[:test_pid], {:event, event})
          :ok
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [StructCheckSink])

      Arca.AuditHandler.handle_event(
        [:cyfr, :sanctum, :auth],
        %{count: 1},
        %{test_pid: test_pid, user_id: "test_user", access_token: "gho_secret"},
        nil
      )

      assert_receive {:event, %Arca.Audit.Event{} = event}
      assert event.user_id == "test_user"
      # A credential riding the emitter's metadata never reaches a sink…
      assert event.metadata[:access_token] == "[REDACTED]"
      # …and no Sanctum context is constructed on the way (constructing one
      # would recurse now that :platform_context is on the roster).
      refute Map.has_key?(event.metadata, :context)
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
        def handle_audit_event(_event) do
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

    # :telemetry detaches a handler that raises, permanently and silently —
    # so anything escaping handle_event/4 would end auditing for that event
    # for the life of the node. The per-sink rescue does not cover the work
    # around the sinks.
    test "a failure outside the sinks does not escape the handler, nor detach it" do
      # A sink list that is not a list of modules makes the dispatch itself
      # raise, outside the per-sink try/rescue. Emitted through
      # `:telemetry.execute/3` — the path that detaches a handler that
      # fails in any class — and the handler must still be attached after.
      Application.put_env(:cyfr, :audit_sinks, :not_a_list)
      event = [:cyfr, :sanctum, :auth]
      before = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
      ours = &Arca.AuditHandler.handle_event/4
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.function == ours))

      log = capture_log(fn -> :telemetry.execute(event, %{count: 1}, %{user_id: "u1"}) end)

      assert log =~ "handler failed"
      assert event |> :telemetry.list_handlers() |> Enum.map(& &1.id) == before
    end
  end

  describe "monitored events" do
    test "a component reaching a credential is audited" do
      test_pid = self()

      defmodule SecretSink do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(%Arca.Audit.Event{} = event) do
          send(event.metadata[:test_pid], {:audit, event.name, event.measurements})
          :ok
        end
      end

      Application.put_env(:cyfr, :audit_sinks, [SecretSink])

      for event <- [[:cyfr, :opus, :secret, :accessed], [:cyfr, :opus, :secret, :denied]] do
        Arca.AuditHandler.handle_event(
          event,
          %{count: 1},
          %{test_pid: test_pid, user_id: "u1"},
          nil
        )

        assert_receive {:audit, ^event, %{count: 1}}
      end
    end

    test "the secret events are attached, not merely handled" do
      # handle_event/4 answers whatever it is handed; what matters is that
      # the roster actually subscribes to these event names.
      attached =
        :telemetry.list_handlers([:cyfr, :opus, :secret, :accessed]) ++
          :telemetry.list_handlers([:cyfr, :opus, :secret, :denied])

      ids = Enum.map(attached, & &1.id)

      assert "audit-cyfr-opus-secret-accessed" in ids
      assert "audit-cyfr-opus-secret-denied" in ids
    end

    test "the platform-context trail is attached" do
      ids =
        [:cyfr, :sanctum, :platform_context]
        |> :telemetry.list_handlers()
        |> Enum.map(& &1.id)

      assert "audit-cyfr-sanctum-platform_context" in ids
    end
  end
end
