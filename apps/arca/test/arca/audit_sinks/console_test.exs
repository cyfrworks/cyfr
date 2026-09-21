# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSinks.ConsoleTest do
  use ExUnit.Case, async: false

  # The sink logs at :info; test env's primary level is :warning, so the
  # level is raised for these assertions (async: false for that reason).

  import ExUnit.CaptureLog

  alias Arca.Audit.Event
  alias Arca.AuditSinks.Console

  setup do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)
  end

  # Capture the log AND the metadata the sink attached — the fields
  # `Cyfr.JsonFormatter` renders. A handler is the only place metadata is
  # visible; `capture_log/2` returns the formatted message alone.
  defp with_log_metadata(fun) do
    parent = self()
    id = String.to_atom("audit_meta_probe_#{System.unique_integer([:positive])}")

    :ok =
      :logger.add_handler(id, :logger_std_h, %{
        config: %{type: :standard_io},
        filters: [
          send_back:
            {fn %{meta: meta}, _ ->
               send(parent, {:log_meta, Map.to_list(meta)})
               :stop
             end, []}
        ]
      })

    log = capture_log([level: :info], fun)
    :ok = :logger.remove_handler(id)

    meta =
      receive do
        {:log_meta, meta} -> meta
      after
        0 -> []
      end

    {log, meta}
  end

  describe "handle_audit_event/1" do
    test "returns :ok and carries identity as Logger metadata, not prose" do
      # `user_id` and `athanor_id` are in `Cyfr.LoggerContext`'s roster, so
      # `Cyfr.JsonFormatter` gives them their own fields. Interpolated into
      # the sentence they were unqueryable under `CYFR_LOG_FORMAT=json` — in
      # the one plane that most needs to be queried by who and by which
      # athanor.
      event = %Event{
        name: [:cyfr, :sanctum, :auth],
        measurements: %{count: 1},
        metadata: %{provider: :github, outcome: :success},
        user_id: "user_1",
        athanor_id: "ath_1"
      }

      {log, metadata} =
        with_log_metadata(fn -> assert :ok = Console.handle_audit_event(event) end)

      assert log =~ "cyfr.sanctum.auth"
      assert metadata[:user_id] == "user_1"
      assert metadata[:athanor_id] == "ath_1"
    end

    test "renders the emitter's discriminating metadata, not a fixed key set" do
      event = %Event{
        name: [:cyfr, :sanctum, :door, :refused],
        measurements: %{count: 1},
        metadata: %{reason: :not_allowlisted, email: "who@example.com"}
      }

      log =
        capture_log([level: :info], fn -> assert :ok = Console.handle_audit_event(event) end)

      assert log =~ "not_allowlisted"
      assert log =~ "who@example.com"
    end

    test "handles empty metadata" do
      event = %Event{
        name: [:cyfr, :opus, :execute, :start],
        measurements: %{duration: 100},
        metadata: %{}
      }

      assert :ok = Console.handle_audit_event(event)
    end
  end
end
