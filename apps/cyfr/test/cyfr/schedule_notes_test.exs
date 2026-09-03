# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ScheduleNotesTest do
  # A schedule that asked to keep its outcome: the handler files a note in
  # the schedule's estate with the run as provenance, capped, and writes
  # nothing for a run nobody asked to keep or into a closed furnace.
  use ExUnit.Case, async: false

  alias Cyfr.ScheduleNotes

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "schedule_notes_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
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
        reference: "daily-report",
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

  test "a completed run that asked to be kept files a note with the run as provenance",
       %{estate: estate, user: user, ctx: ctx} do
    metadata = completed(estate, user)
    assert :ok = fire(metadata)

    assert {:ok, note} = Aqua.Notes.read(ctx, "schedule-daily-report")
    assert note.content =~ "42 rows reconciled"
    assert note.kept_by == "schedule:" <> metadata.schedule_id
    assert note.execution == "exec_1"
  end

  test "note_name names the note; a string output is kept as it is; a long one is cut with a marker",
       %{estate: estate, user: user, ctx: ctx} do
    long = String.duplicate("é", 40_000)

    assert :ok =
             fire(
               completed(estate, user, %{
                 output: long,
                 metadata: ~s({"keep_outcome": true, "note_name": "reconciliation"})
               })
             )

    assert {:ok, note} = Aqua.Notes.read(ctx, "reconciliation")
    assert String.valid?(note.content)
    assert String.ends_with?(note.content, "longer than 64 KiB]")
    assert byte_size(note.content) <= 64 * 1024 + 100
    assert {:error, _} = Aqua.Notes.read(ctx, "schedule-daily-report")
  end

  test "a run nobody asked to keep, or with unreadable metadata, writes nothing",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok = fire(completed(estate, user, %{metadata: nil}))
    assert :ok = fire(completed(estate, user, %{metadata: ~s({"keep_outcome": false})}))
    assert :ok = fire(completed(estate, user, %{metadata: "not json"}))
    assert {:ok, []} = Aqua.Notes.list(ctx)
  end

  test "a name the ledger refuses is logged, not raised, and the run stands",
       %{estate: estate, user: user, ctx: ctx} do
    assert :ok =
             fire(
               completed(estate, user, %{
                 metadata: ~s({"keep_outcome": true, "note_name": "../escape"})
               })
             )

    assert {:ok, []} = Aqua.Notes.list(ctx)
  end

  test "an archived athanor's schedule writes nothing", %{estate: estate, user: user, ctx: ctx} do
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(estate)
    assert :ok = fire(completed(estate, user))
    assert {:ok, []} = Aqua.Notes.list(ctx)
  end

  test "the handler is attached at boot, once" do
    ids = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert "notes-schedule-completed" in ids
    assert :ok = ScheduleNotes.attach()
    ids = ScheduleNotes.event() |> :telemetry.list_handlers() |> Enum.map(& &1.id)
    assert Enum.count(ids, &(&1 == "notes-schedule-completed")) == 1
  end
end
