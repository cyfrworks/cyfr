# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditHandlerTest do
  @moduledoc """
  What reaches the audit trail, and what a failure writing it does.

  The trail is read here the way a deployment's own reads it: by attaching
  to `[:cyfr, :audit, :recorded]`, the one event `Arca.AuditHandler` emits
  per entry, carrying the `Arca.Audit.Event` it built with the emitter's
  metadata sanitized. That attach is the extension point a list of sink
  modules in configuration used to be.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Every entry the handler records while `fun` runs.
  defp recorded(fun) do
    test = self()
    id = "audit-handler-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:cyfr, :audit, :recorded],
      fn _event, measurements, %{audited: audited}, _config ->
        send(test, {:recorded, audited, measurements})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  defp emit(name, measurements, metadata),
    do: Arca.AuditHandler.handle_event(name, measurements, metadata, nil)

  describe "handle_event/4" do
    test "an audited event reaches the trail, named, with its measurements" do
      recorded(fn -> emit([:cyfr, :sanctum, :auth], %{count: 1}, %{user_id: "u1"}) end)

      assert_receive {:recorded, %Arca.Audit.Event{name: [:cyfr, :sanctum, :auth]}, %{count: 1}}
    end

    test "the shipped trail is a log line, for a deployment that attaches nothing" do
      # The trail goes out at :info and the suite runs at :warning, which
      # is the property the line itself documents: a node that raises its
      # level keeps its operational logging and loses this trail.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          emit([:cyfr, :sanctum, :auth], %{count: 1}, %{user_id: "u1", reason: "bad_password"})
        end)

      assert log =~ "[Audit] cyfr.sanctum.auth"
      assert log =~ "bad_password"
    end

    test "sanitizes metadata and constructs no context" do
      recorded(fn ->
        emit(
          [:cyfr, :sanctum, :auth],
          %{count: 1},
          %{user_id: "test_user", access_token: "gho_secret"}
        )
      end)

      assert_receive {:recorded, %Arca.Audit.Event{} = event, _measurements}
      assert event.user_id == "test_user"
      # A credential riding the emitter's metadata never reaches the trail…
      assert event.metadata[:access_token] == "[REDACTED]"
      # Audit handling must not construct a context and recursively emit another audit event.
      refute Map.has_key?(event.metadata, :context)
    end

    test "recording an entry is not itself audited" do
      # `[:cyfr, :audit, :recorded]` is outside the audit roster, so the
      # handler cannot be attached to what it emits.
      refute [:cyfr, :audit, :recorded] in Cyfr.Telemetry.Catalog.consumed_by(:audit)
    end

    # :telemetry detaches a handler that raises, permanently and silently —
    # so anything escaping handle_event/4 would end auditing for that event
    # for the life of the node.
    test "a failure writing the trail does not escape the handler, nor detach it" do
      test_pid = self()

      :telemetry.attach(
        "test-pipeline-failure",
        [:cyfr, :audit, :pipeline_failure],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:pipeline_failure, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-pipeline-failure") end)

      # A value that looks like a struct of a module this node does not
      # have makes the sanitizer raise, which is a failure with nothing
      # around it to rescue. Emitted through `:telemetry.execute/3` — the
      # path that detaches a handler that fails in any class — and the
      # handler must still be attached after.
      event = [:cyfr, :sanctum, :auth]
      before = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
      ours = &Arca.AuditHandler.handle_event/4
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.function == ours))

      metadata = %{user_id: "u1", detail: %{__struct__: Arca.AuditHandlerTest.NoSuchStruct, a: 1}}
      log = capture_log(fn -> :telemetry.execute(event, %{count: 1}, metadata) end)

      assert log =~ "handler failed"
      assert event |> :telemetry.list_handlers() |> Enum.map(& &1.id) == before

      assert_receive {:pipeline_failure, [:cyfr, :audit, :pipeline_failure], %{count: 1},
                      %{event: [:cyfr, :sanctum, :auth]}}
    end
  end

  describe "the roster" do
    # The roster is settled at start, not compiled in: the boot reads the
    # catalog and hands the answer to `start_link/1`. Both directions are
    # held here — a catalog entry with no attached handler, and an
    # attached handler for an event the catalog does not name for audit —
    # so a planted mismatch either way fails.
    test "the handler is attached to exactly the catalog's :audit set" do
      rostered = Cyfr.Telemetry.Catalog.consumed_by(:audit)

      assert Arca.AuditHandler.events() == rostered

      expected = MapSet.new(rostered, &("audit-" <> Enum.join(&1, "-")))

      # Every handler on the node, not only the rostered events', so an
      # audit handler attached to an event the catalog does not name for
      # audit is caught too.
      attached =
        for handler <- :telemetry.list_handlers([]),
            is_binary(handler.id),
            String.starts_with?(handler.id, "audit-"),
            into: MapSet.new(),
            do: handler.id

      assert attached == expected
    end

    test "a boot that names no roster does not start" do
      # An empty roster audits nothing and says nothing about it, so the
      # option is required rather than defaulted.
      assert_raise KeyError, fn -> Arca.AuditHandler.init([]) end
    end
  end

  describe "monitored events" do
    test "a credential dispensed to a runner, and one a runner reports refused, are audited" do
      for event <- [[:cyfr, :opus, :secret, :dispensed], [:cyfr, :opus, :secret, :denied]] do
        recorded(fn -> emit(event, %{count: 1}, %{user_id: "u1"}) end)

        assert_receive {:recorded, %Arca.Audit.Event{name: ^event}, %{count: 1}}
      end
    end

    test "a secret entry reaches the trail naming its field and its attempt, the name unredacted" do
      identity = %{
        athanor_id: "ath_1",
        user_id: "usr_1",
        execution_id: "exec_1",
        attempt: "att_1",
        fence: 1,
        component_ref: "catalyst:local.x:0.1.0",
        consent_id: "cons_1",
        runner: "runner_1",
        service: "wrk_1",
        field: "API_KEY"
      }

      for event <- [[:cyfr, :opus, :secret, :dispensed], [:cyfr, :opus, :secret, :denied]] do
        recorded(fn -> emit(event, %{system_time: 1}, identity) end)

        assert_receive {:recorded, %Arca.Audit.Event{name: ^event} = audited, _measurements}
        assert audited.athanor_id == "ath_1" and audited.user_id == "usr_1"
        assert audited.metadata == identity
      end
    end

    test "the secret events are attached, not merely handled" do
      # handle_event/4 answers whatever it is handed; what matters is that
      # the roster actually subscribes to these event names.
      attached =
        :telemetry.list_handlers([:cyfr, :opus, :secret, :dispensed]) ++
          :telemetry.list_handlers([:cyfr, :opus, :secret, :denied])

      ids = Enum.map(attached, & &1.id)

      assert "audit-cyfr-opus-secret-dispensed" in ids
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
