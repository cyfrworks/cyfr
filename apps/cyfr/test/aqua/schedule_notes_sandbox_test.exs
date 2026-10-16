# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotesSandboxTest do
  # The schedule-notes keeper under the test sandbox: a tick with no
  # connection owner does not take it down, and no keeper the application
  # started works a test's records on the connection that test lent.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aqua.ScheduleNotes

  defp enabled! do
    previous = Application.fetch_env(:cyfr, :schedule_notes_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cyfr, :schedule_notes_enabled, value)
        :error -> Application.delete_env(:cyfr, :schedule_notes_enabled)
      end
    end)

    Application.put_env(:cyfr, :schedule_notes_enabled, true)
  end

  # An outcome record of a run nobody asked to keep, in an athanor of its
  # own: a drain answers it `applied` and writes nothing else.
  defp pending_record! do
    athanor_id = "ath_notes_sandbox_#{System.unique_integer([:positive])}"
    actor = Prima.Actor.in_athanor(athanor_id)
    now = DateTime.utc_now()

    record =
      Prima.OutboxRecord.schedule_outcome(%{
        occurrence: %{
          id: Prima.UUID7.generate_id("occ"),
          athanor_id: athanor_id,
          scheduled_for: now,
          execution_id: Prima.UUID7.execution_id(),
          note_revision_read: nil
        },
        schedule: %{id: "sched_notes_sandbox", profile_id: "prof_notes_sandbox", updated_at: now},
        consent_revision: nil,
        keep: {false, nil},
        output: "not for keeping"
      })

    :ok = Arca.Outbox.put!(actor, record)
    assert {:ok, [_]} = Arca.Outbox.pending(actor, "schedule_notes", "schedule_outcome")
    {actor, record}
  end

  defp untouched!({actor, record}) do
    receipt =
      Arca.ConsumerReceipts.outcome(actor, "schedule_notes", Prima.OutboxRecord.source(record))

    pending = Arca.Outbox.pending(actor, "schedule_notes", "schedule_outcome")

    assert {match?({:ok, [_]}, pending), receipt} == {true, :none},
           "a keeper worked this test's record: pending=#{inspect(pending)}, receipt=#{inspect(receipt)}"
  end

  test "a keeper's tick with no connection owner is logged, and the keeper lives" do
    enabled!()

    log =
      capture_log(fn ->
        # No sandbox owner here: its boot drain and the forced tick after
        # it both read with no connection to read on.
        name = Aqua.ScheduleNotesSandboxTest.Keeper
        keeper = start_supervised!({ScheduleNotes, name: name, tick_ms: :timer.hours(1)})
        send(keeper, :drain_all)
        :sys.get_state(keeper)
        assert Process.whereis(name) == keeper
      end)

    assert log =~ "[ScheduleNotes] pending records not read"
  end

  describe "under a test's shared sandbox" do
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
      :ok
    end

    test "a pending record nobody drains stays pending" do
      pending_record!() |> untouched!()
    end

    test "the application starts no keeper, so no tick of one works the test's record" do
      record = pending_record!()

      # A forced tick of whatever keeper the application runs, as its
      # timer would deliver it: under the suite there is none.
      with keeper when is_pid(keeper) <- Process.whereis(ScheduleNotes) do
        send(keeper, :drain_all)
        :sys.get_state(keeper)
      end

      untouched!(record)
      assert Process.whereis(ScheduleNotes) == nil

      # Its supervisor starting it again starts nothing either.
      assert {:ok, :undefined} = Supervisor.restart_child(Aqua.Supervisor, ScheduleNotes)
      assert Process.whereis(ScheduleNotes) == nil
      untouched!(record)
    end
  end
end
