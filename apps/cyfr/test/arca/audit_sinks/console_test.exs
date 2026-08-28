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

  describe "handle_audit_event/1" do
    test "returns :ok and renders identity fields" do
      event = %Event{
        name: [:cyfr, :sanctum, :auth],
        measurements: %{count: 1},
        metadata: %{provider: :github, outcome: :success},
        user_id: "user_1",
        athanor_id: "ath_1"
      }

      log =
        capture_log([level: :info], fn -> assert :ok = Console.handle_audit_event(event) end)

      assert log =~ "cyfr.sanctum.auth"
      assert log =~ "user_id=user_1"
      assert log =~ "athanor_id=ath_1"
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
