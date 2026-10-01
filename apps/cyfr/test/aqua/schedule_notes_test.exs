# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleNotesTest.Between do
  @moduledoc false
  # A storage cap that runs, once, what the test planted in the asking
  # process: `Arca.Storage.stage/3` asks it after the outcome's note was
  # read and before it is published.
  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, _count), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{}, _incoming) do
    case Process.delete(__MODULE__) do
      nil -> :ok
      between -> between.()
    end

    :ok
  end
end

defmodule Aqua.ScheduleNotesTest do
  # A schedule that asked to keep its outcome: the committed completion
  # files a note in the schedule's athanor with the run as provenance,
  # capped, once per execution, and only on the member that issued it; a
  # run nobody asked to keep, a closed furnace or a lost slot writes
  # nothing.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Aqua.ScheduleNotes
  alias Cyfr.Bus.ScheduleCompleted

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

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
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Ops #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}
    {:ok, user: user, athanor: athanor, ctx: ctx}
  end

  # What the scheduler publishes once the occurrence's close and the run's
  # record committed, from this member's own slot.
  defp completed(athanor, user, overrides \\ %{}) do
    actor = %{Prima.Actor.in_athanor(athanor.id) | user_id: user}

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
       %{athanor: athanor, user: user, ctx: ctx} do
    completion = completed(athanor, user)
    assert :kept = ScheduleNotes.keep(completion)

    assert {:ok, note} = Aqua.Notes.read(ctx, completion.schedule_id)
    assert note.content =~ "42 rows reconciled"
    assert note.kept_by == "schedule:" <> completion.schedule_id
    assert note.execution == completion.execution_id
  end

  test "the next run replaces the note before it", %{athanor: athanor, user: user, ctx: ctx} do
    first = completed(athanor, user)
    assert :kept = ScheduleNotes.keep(first)

    next =
      completed(athanor, user, %{
        schedule_id: first.schedule_id,
        output: %{"summary" => "43 rows"}
      })

    assert :kept = ScheduleNotes.keep(next)

    assert {:ok, note} = Aqua.Notes.read(ctx, first.schedule_id)
    assert note.content =~ "43 rows"
    refute note.content =~ "42 rows"
    assert {:ok, %{notes: [_]}} = Aqua.Notes.list(ctx)
  end

  test "the same completion delivered twice keeps one note, once", %{
    athanor: athanor,
    user: user,
    ctx: ctx
  } do
    completion = completed(athanor, user)
    assert :kept = ScheduleNotes.keep(completion)
    {:ok, %{kept_at: kept_at}} = Aqua.Notes.read(ctx, completion.schedule_id)

    assert :duplicate = ScheduleNotes.keep(completion)
    assert {:ok, %{notes: [_]}} = Aqua.Notes.list(ctx)
    assert {:ok, %{kept_at: ^kept_at}} = Aqua.Notes.read(ctx, completion.schedule_id)
  end

  test "note_name names the note; a string output is kept as it is; a long one is cut with a marker",
       %{athanor: athanor, user: user, ctx: ctx} do
    long = String.duplicate("é", 40_000)
    completion = completed(athanor, user, %{output: long, note_name: "reconciliation"})
    assert completion.truncated

    assert :kept = ScheduleNotes.keep(completion)

    assert {:ok, note} = Aqua.Notes.read(ctx, "reconciliation")
    assert String.valid?(note.content)
    assert String.ends_with?(note.content, "longer than 64 KiB]")
    assert byte_size(note.content) <= 64 * 1024 + 100
    assert {:error, _} = Aqua.Notes.read(ctx, completion.schedule_id)
  end

  test "a note_name the ledger's grammar refuses writes nothing, and the id is not used instead",
       %{athanor: athanor, user: user, ctx: ctx} do
    assert :not_kept =
             ScheduleNotes.keep(completed(athanor, user, %{note_name: "nightly: sync"}))

    assert :not_kept = ScheduleNotes.keep(completed(athanor, user, %{note_name: "../escape"}))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "a run nobody asked to keep writes nothing", %{athanor: athanor, user: user, ctx: ctx} do
    assert :skipped = ScheduleNotes.keep(completed(athanor, user, %{keep_outcome: false}))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  test "an archived athanor's schedule writes nothing", %{athanor: athanor, user: user, ctx: ctx} do
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(athanor)
    assert :skipped = ScheduleNotes.keep(completed(athanor, user))
    assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
  end

  describe "the issuer" do
    test "another member's completion writes nothing here", %{
      athanor: athanor,
      user: user,
      ctx: ctx
    } do
      peer = %{node: "peer@host", owner: "boot_peer", generation: 1}
      assert :skipped = ScheduleNotes.keep(completed(athanor, user, %{issuer_member: peer}))
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "a member that does not hold its slot writes nothing", %{
      athanor: athanor,
      user: user,
      ctx: ctx
    } do
      completion = completed(athanor, user)
      ControlPlane.record(:lost)
      assert :skipped = ScheduleNotes.keep(completion)
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end
  end

  describe "the publication" do
    setup do
      keys = [{ControlPlane, :standing}, {ControlPlane, :generation}, {ControlPlane, :slot}]
      saved = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
      installed = Prima.Caps.impl!()
      Prima.Caps.install!(Aqua.ScheduleNotesTest.Between)

      on_exit(fn ->
        Prima.Caps.install!(installed)

        for {key, value} <- saved do
          if value == :absent,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end
      end)

      node = "node-sched-#{System.unique_integer([:positive])}"
      {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
      {:ok, slot: slot}
    end

    test "is kept under the member's own slot", %{athanor: athanor, user: user, ctx: ctx} do
      completion = completed(athanor, user)
      assert :kept = ScheduleNotes.keep(completion)
      assert {:ok, %{execution: execution}} = Aqua.Notes.read(ctx, completion.schedule_id)
      assert execution == completion.execution_id
    end

    test "a note someone kept after it was read stands, and the outcome is not written over it",
         %{athanor: athanor, user: user, ctx: ctx} do
      completion = completed(athanor, user, %{note_name: "nightly"})
      plant(fn -> {:ok, _} = Aqua.Notes.keep(ctx, "nightly", "kept by hand") end)

      assert :not_kept = ScheduleNotes.keep(completion)
      assert {:ok, %{content: "kept by hand", execution: nil}} = Aqua.Notes.read(ctx, "nightly")
    end

    test "a slot taken over between the read and the publication publishes nothing",
         %{athanor: athanor, user: user, ctx: ctx, slot: slot} do
      completion = completed(athanor, user)
      plant(fn -> take_over!(slot) end)

      assert :not_kept = ScheduleNotes.keep(completion)
      assert {:error, {:not_found, "note", _}} = Aqua.Notes.read(ctx, completion.schedule_id)
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    test "a slot that ran out with no successor publishes nothing",
         %{athanor: athanor, user: user, ctx: ctx, slot: slot} do
      completion = completed(athanor, user)
      plant(fn -> expire!(slot) end)

      assert :not_kept = ScheduleNotes.keep(completion)
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
    end

    defp plant(between), do: Process.put(Aqua.ScheduleNotesTest.Between, between)

    defp take_over!(%{node: node, generation: generation, fence: fence}) do
      {1, _} =
        Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
          set: [owner: node <> "#boot_b", generation: generation + 1, fence: fence + 1]
        )

      :ok
    end

    defp expire!(%{node: node}) do
      past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

      {1, _} =
        Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
          set: [lease_until: past]
        )

      :ok
    end
  end

  describe "the process" do
    test "hears the committed completion on the bus and keeps its note", %{
      athanor: athanor,
      user: user,
      ctx: ctx
    } do
      completion = completed(athanor, user)
      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)

      # One round trip: the completion ahead of it has been handled.
      :sys.get_state(ScheduleNotes)
      assert {:ok, %{execution: execution}} = Aqua.Notes.read(ctx, completion.schedule_id)
      assert execution == completion.execution_id
    end

    test "is subscribed again after a restart", %{athanor: athanor, user: user, ctx: ctx} do
      before = Process.whereis(ScheduleNotes)
      ref = Process.monitor(before)
      Process.exit(before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^before, :killed}

      :ok =
        Prima.Test.Wait.wait_until(
          fn -> Process.whereis(ScheduleNotes) not in [nil, before] end,
          5_000,
          "the notes keeper to restart"
        )

      restarted = Process.whereis(ScheduleNotes)
      assert Cyfr.Bus.schedule_completions() in Registry.keys(Cyfr.PubSub, restarted)

      completion = completed(athanor, user)
      :ok = Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion)
      :sys.get_state(ScheduleNotes)
      assert {:ok, _note} = Aqua.Notes.read(ctx, completion.schedule_id)
    end

    test "survives a completion that cannot be kept" do
      completion =
        ScheduleCompleted.new(Prima.Actor.in_athanor("ath_nowhere"), %{
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
