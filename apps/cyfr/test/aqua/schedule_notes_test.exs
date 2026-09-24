# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotesTest do
  # A schedule that asked to keep its outcome: the handler files a note in
  # the schedule's estate with the run as provenance, capped, and writes
  # nothing for a run nobody asked to keep or into a closed furnace.
  use ExUnit.Case, async: false

  alias Aqua.ScheduleNotes

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "schedule_notes_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    n = System.unique_integer([:positive])
    user = "local|idp|sched-#{n}"
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Ops #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}
    {:ok, user: user, estate: estate, ctx: ctx}
  end

  defp completed(estate, user, overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "req_1",
        schedule_id: "sched_#{System.unique_integer([:positive])}",
        # What the scheduler really carries: the pinned component reference,
        # which the ledger's name grammar would refuse as a note name.
        reference: "formula:local.daily-report:1.2.3",
        execution_id: "exec_1",
        athanor_id: estate.id,
        user_id: user,
        output: %{"summary" => "42 rows reconciled"},
        metadata: ~s({"keep_outcome": true})
      },
      overrides
    )
  end

  defp fire(metadata), do: ScheduleNotes.handle_event(ScheduleNotes.event(), %{}, metadata, nil)

  test "a completed run that asked to be kept files a note, named by the schedule's id, with the run as provenance",
       %{estate: estate, user: user, ctx: ctx} do
    metadata = completed(estate, user)
    assert :ok = fire(metadata)

    assert {:ok, note} = Aqua.Notes.read(ctx, metadata.schedule_id)
    assert note.content =~ "42 rows reconciled"
    assert note.kept_by == "schedule:" <> metadata.schedule_id
    assert note.execution == "exec_1"
  end

  test "the next run replaces the note before it", %{estate: estate, user: user, ctx: ctx} do
    metadata = completed(estate, user)
    assert :ok = fire(metadata)
    assert :ok = fire(%{metadata | output: %{"summary" => "43 rows reconciled"}})

    assert {:ok, note} = Aqua.Notes.read(ctx, metadata.schedule_id)
    assert note.content =~ "43 rows"
    refute note.content =~ "42 rows"
    assert {:ok, %{notes: [_]}} = Aqua.Notes.list(ctx)
  end

  test "note_name names the note; a string output is kept as it is; a long one is cut with a marker",
       %{estate: estate, user: user, ctx: ctx} do
    long = String.duplicate("é", 40_000)

    metadata =
      completed(estate, user, %{
        output: long,
        metadata: ~s({"keep_outcome": true, "note_name": "reconciliation"})
      })

    assert :ok = fire(metadata)

    assert {:ok, note} = Aqua.Notes.read(ctx, "reconciliation")
    assert String.valid?(note.content)
    assert String.ends_with?(note.content, "longer than 64 KiB]")
    assert byte_size(note.content) <= 64 * 1024 + 100
    assert {:error, _} = Aqua.Notes.read(ctx, metadata.schedule_id)
  end

  test "a note_name the ledger's grammar refuses writes nothing, and the id is not used instead",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok =
             fire(
               completed(estate, user, %{
                 metadata: ~s({"keep_outcome": true, "note_name": "nightly: sync"})
               })
             )

    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "a run nobody asked to keep, or with unreadable metadata, writes nothing",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok = fire(completed(estate, user, %{metadata: nil}))
    assert :ok = fire(completed(estate, user, %{metadata: ~s({"keep_outcome": false})}))
    assert :ok = fire(completed(estate, user, %{metadata: "not json"}))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "a name the ledger refuses is logged, not raised, and the run stands",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok =
             fire(
               completed(estate, user, %{
                 metadata: ~s({"keep_outcome": true, "note_name": "../escape"})
               })
             )

    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "an event that names no athanor is logged, not raised", %{estate: estate, user: user} do
    assert :ok = fire(completed(estate, user, %{athanor_id: nil}))
  end

  test "a failure inside the handler does not detach it", %{estate: estate, user: user} do
    # Through `:telemetry.execute/3`, which detaches a handler that fails
    # in any class: an athanor that is not even a string makes the
    # crossing raise deep inside, and the handler must still be listed
    # afterwards. Exits and throws share the same catch.
    before = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert "notes-schedule-completed" in before

    :telemetry.execute(
      ScheduleNotes.event(),
      %{},
      completed(estate, user, %{athanor_id: :nowhere})
    )

    after_ = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert "notes-schedule-completed" in after_
  end

  test "an archived athanor's schedule writes nothing", %{estate: estate, user: user, ctx: ctx} do
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(estate)
    assert :ok = fire(completed(estate, user))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "the handler is attached at boot, once" do
    ids = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert "notes-schedule-completed" in ids
    assert :ok = ScheduleNotes.attach()
    ids = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert Enum.count(ids, &(&1 == "notes-schedule-completed")) == 1
  end

  test "attaching again keeps one handler, so one completed run files one note",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok = ScheduleNotes.attach()
    assert :ok = ScheduleNotes.attach()

    handlers =
      ScheduleNotes.event()
      |> :telemetry.list_handlers()
      |> Enum.filter(&(&1.id == "notes-schedule-completed"))

    assert [%{function: function}] = handlers
    assert function == (&ScheduleNotes.handle_event/4)

    metadata = completed(estate, user)
    :telemetry.execute(ScheduleNotes.event(), %{}, metadata)

    assert {:ok, %{notes: [%{name: name}]}} = Aqua.Notes.list(ctx)
    assert name == metadata.schedule_id
  end
end
