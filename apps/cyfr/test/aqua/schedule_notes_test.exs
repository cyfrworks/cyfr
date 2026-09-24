# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotesTest do
  # A schedule that asked to keep its outcome: the committed completion
  # files a note in the schedule's estate with the run as provenance,
  # capped, once per execution, and only on the member that issued it; a
  # run nobody asked to keep, a closed furnace or a lost slot writes
  # nothing.
  use ExUnit.Case, async: false

  alias Arca.ControlPlane
  alias Aqua.ScheduleNotes
  alias Cyfr.Bus.ScheduleCompleted

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

    on_exit(fn -> ControlPlane.record(:unclaimed) end)

    n = System.unique_integer([:positive])
    user = "local|idp|sched-#{n}"
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Ops #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}
    {:ok, user: user, estate: estate, ctx: ctx}
  end

  # What the scheduler publishes once the occurrence's close and the run's
  # record committed, from this member's own slot.
  defp completed(estate, user, overrides \\ %{}) do
    actor = %{Cyfr.Actor.in_athanor(estate.id) | user_id: user}

    fields =
      Map.merge(
        %{
          issuer_member: ScheduleCompleted.issuer(ControlPlane.held()),
          schedule_id: "sched_#{System.unique_integer([:positive])}",
          execution_id: "exec_#{System.unique_integer([:positive])}",
          occurrence_id: "occ_1",
          completed_at: DateTime.utc_now(),
          keep_outcome: true,
          output: %{"summary" => "42 rows reconciled"}
        },
        overrides
      )

    ScheduleCompleted.new(actor, fields)
  end

  test "a completed run that asked to be kept files a note, named by the schedule's id, with the run as provenance",
       %{estate: estate, user: user, ctx: ctx} do
    completion = completed(estate, user)
    assert :kept = ScheduleNotes.keep(completion)

    assert {:ok, note} = Aqua.Notes.read(ctx, completion.schedule_id)
    assert note.content =~ "42 rows reconciled"
    assert note.kept_by == "schedule:" <> completion.schedule_id
    assert note.execution == completion.execution_id
  end

  test "the next run replaces the note before it", %{estate: estate, user: user, ctx: ctx} do
    first = completed(estate, user)
    assert :kept = ScheduleNotes.keep(first)

    next =
      completed(estate, user, %{schedule_id: first.schedule_id, output: %{"summary" => "43 rows"}})

    assert :kept = ScheduleNotes.keep(next)

    assert {:ok, note} = Aqua.Notes.read(ctx, first.schedule_id)
    assert note.content =~ "43 rows"
    refute note.content =~ "42 rows"
    assert {:ok, %{notes: [_]}} = Aqua.Notes.list(ctx)
  end

  test "the same completion delivered twice keeps one note, once", %{
    estate: estate,
    user: user,
    ctx: ctx
  } do
    completion = completed(estate, user)
    assert :kept = ScheduleNotes.keep(completion)
    {:ok, %{kept_at: kept_at}} = Aqua.Notes.read(ctx, completion.schedule_id)

    assert :duplicate = ScheduleNotes.keep(completion)
    assert {:ok, %{notes: [_]}} = Aqua.Notes.list(ctx)
    assert {:ok, %{kept_at: ^kept_at}} = Aqua.Notes.read(ctx, completion.schedule_id)
  end

  test "note_name names the note; a string output is kept as it is; a long one is cut with a marker",
       %{estate: estate, user: user, ctx: ctx} do
    long = String.duplicate("é", 40_000)
    completion = completed(estate, user, %{output: long, note_name: "reconciliation"})
    assert completion.truncated

    assert :kept = ScheduleNotes.keep(completion)

    assert {:ok, note} = Aqua.Notes.read(ctx, "reconciliation")
    assert String.valid?(note.content)
    assert String.ends_with?(note.content, "longer than 64 KiB]")
    assert byte_size(note.content) <= 64 * 1024 + 100
    assert {:error, _} = Aqua.Notes.read(ctx, completion.schedule_id)
  end

  test "a note_name the ledger's grammar refuses writes nothing, and the id is not used instead",
       %{estate: estate, user: user, ctx: ctx} do
    assert :not_kept =
             ScheduleNotes.keep(completed(estate, user, %{note_name: "nightly: sync"}))

    assert :not_kept = ScheduleNotes.keep(completed(estate, user, %{note_name: "../escape"}))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "a run nobody asked to keep writes nothing", %{estate: estate, user: user, ctx: ctx} do
    assert :skipped = ScheduleNotes.keep(completed(estate, user, %{keep_outcome: false}))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "an archived athanor's schedule writes nothing", %{estate: estate, user: user, ctx: ctx} do
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(estate)
    assert :skipped = ScheduleNotes.keep(completed(estate, user))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  describe "the issuer" do
    test "another member's completion writes nothing here", %{
      estate: estate,
      user: user,
      ctx: ctx
    } do
      peer = %{node: "peer@host", owner: "boot_peer", generation: 1}
      assert :skipped = ScheduleNotes.keep(completed(estate, user, %{issuer_member: peer}))
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "a member that does not hold its slot writes nothing", %{
      estate: estate,
      user: user,
      ctx: ctx
    } do
      completion = completed(estate, user)
      ControlPlane.record(:lost)
      assert :skipped = ScheduleNotes.keep(completion)
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end
  end

  describe "the process" do
    test "hears the committed completion on the bus and keeps its note", %{
      estate: estate,
      user: user,
      ctx: ctx
    } do
      completion = completed(estate, user)
      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)

      # One round trip: the completion ahead of it has been handled.
      :sys.get_state(ScheduleNotes)
      assert {:ok, %{execution: execution}} = Aqua.Notes.read(ctx, completion.schedule_id)
      assert execution == completion.execution_id
    end

    test "is subscribed again after a restart", %{estate: estate, user: user, ctx: ctx} do
      before = Process.whereis(ScheduleNotes)
      ref = Process.monitor(before)
      Process.exit(before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^before, :killed}

      :ok =
        Cyfr.Test.Wait.wait_until(
          fn -> Process.whereis(ScheduleNotes) not in [nil, before] end,
          5_000,
          "the notes keeper to restart"
        )

      restarted = Process.whereis(ScheduleNotes)
      assert Cyfr.Bus.schedule_completions() in Registry.keys(Cyfr.PubSub, restarted)

      completion = completed(estate, user)
      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)
      :sys.get_state(ScheduleNotes)
      assert {:ok, _note} = Aqua.Notes.read(ctx, completion.schedule_id)
    end

    test "survives a completion that cannot be kept" do
      completion =
        ScheduleCompleted.new(Cyfr.Actor.in_athanor("ath_nowhere"), %{
          schedule_id: "s",
          execution_id: "e",
          keep_outcome: true,
          issuer_member: ScheduleCompleted.issuer(ControlPlane.held()),
          output: "x"
        })

      pid = Process.whereis(ScheduleNotes)
      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)
      :sys.get_state(ScheduleNotes)
      assert Process.whereis(ScheduleNotes) == pid
    end
  end
end
