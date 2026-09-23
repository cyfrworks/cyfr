# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ScheduleOccurrencesTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{CronSchedule, ScheduleOccurrences}

  # Taking a cell slot for a stand-in member writes this VM's one standing
  # record, which every gate in the suite reads: each case puts back what
  # it found rather than deciding another file's run.
  @standing_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    saved = for key <- @standing_keys, do: {key, :persistent_term.get(key, :absent)}

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    {:ok, actor: Arca.Test.Actor.local()}
  end

  defp due!(actor, attrs \\ %{}) do
    {:ok, schedule} =
      CronSchedule.create(
        Map.merge(
          %{
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            name: "occ-#{System.unique_integer([:positive])}",
            cron_expression: "0 * * * *",
            reference: "reagent:local.test:1.0.0",
            resolved_reference: "reagent:local.test:1.0.0",
            profile_id: "prof_test"
          },
          attrs
        )
      )

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  # The cursor of an existing schedule, moved back so its next occurrence is due.
  defp due_again!(%CronSchedule{} = schedule) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp next_occurrence, do: DateTime.add(DateTime.utc_now(), 300, :second)

  defp now, do: Arca.ServerMetaStorage.now!()

  # A member's slot put past its lease on the cell's clock: the one
  # condition that takes it off the roster, made rather than waited for.
  defp expire(member) do
    past = DateTime.add(now(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^member),
        set: [lease_until: past]
      )

    :ok
  end

  defp cursor!(id) do
    {:ok, row} = CronSchedule.get_for_daemon(id)
    row.next_run_at
  end

  test "one claimant wins the occurrence and the cursor moves with it", %{actor: actor} do
    schedule = due!(actor)
    advanced_to = next_occurrence()

    results =
      for node <- ["node-a", "node-b", "node-c"] do
        ScheduleOccurrences.claim(schedule, node, advanced_to)
      end

    assert [{:ok, %{state: "claimed", claimed_by: winner}}] =
             Enum.filter(results, &match?({:ok, _}, &1))

    assert Enum.count(results, &(&1 == :held)) == 2
    assert winner in ["node-a", "node-b", "node-c"]
    assert DateTime.compare(cursor!(schedule.id), advanced_to) == :eq

    # The row the winner holds names the time it was due for; a stale
    # copy of the schedule (its cursor already moved) claims nothing.
    assert {:ok, [%{scheduled_for: due_for}]} =
             ScheduleOccurrences.list(actor, schedule.id)

    assert DateTime.compare(due_for, schedule.next_run_at) == :eq
    assert :held = ScheduleOccurrences.claim(schedule, "node-d", next_occurrence())
  end

  test "an occurrence not yet due, or a schedule without a cursor, is not claimed", %{
    actor: actor
  } do
    schedule = due!(actor)
    future = DateTime.add(DateTime.utc_now(), 600, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: future]
      )

    assert :held =
             ScheduleOccurrences.claim(
               %{schedule | next_run_at: future},
               "node-a",
               next_occurrence()
             )

    assert :held =
             ScheduleOccurrences.claim(
               %{schedule | next_run_at: nil},
               "node-a",
               next_occurrence()
             )

    assert {:ok, []} = ScheduleOccurrences.list(actor, schedule.id)
  end

  test "forbid holds a due occurrence while another is open; allow claims it", %{actor: actor} do
    forbid = due!(actor, %{concurrency: "forbid"})
    allow = due!(actor, %{concurrency: "allow"})

    # Each schedule has an occurrence open, and its next one already due.
    for schedule <- [forbid, allow] do
      {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

      assert 1 =
               ScheduleOccurrences.start!(
                 actor,
                 occurrence.id,
                 "exec_#{occurrence.id}"
               )
    end

    forbid = due_again!(forbid)
    allow = due_again!(allow)

    assert :overlapping = ScheduleOccurrences.claim(forbid, "node-a", next_occurrence())
    assert DateTime.compare(cursor!(forbid.id), forbid.next_run_at) == :eq

    assert {:ok, [%{state: "started"}]} =
             ScheduleOccurrences.list(actor, forbid.id)

    assert {:ok, %{state: "claimed"}} =
             ScheduleOccurrences.claim(allow, "node-a", next_occurrence())

    assert {:ok, [_, _]} = ScheduleOccurrences.list(actor, allow.id)

    # Once the open one ends, forbid claims the waiting occurrence.
    {:ok, [open]} = ScheduleOccurrences.list(actor, forbid.id)
    assert {:ok, 1} = ScheduleOccurrences.finish(actor, open.id, "completed")

    assert {:ok, %{state: "claimed"}} =
             ScheduleOccurrences.claim(forbid, "node-a", next_occurrence())
  end

  test "start moves a claimed occurrence once; finish and settle_dead end it as the row says", %{
    actor: actor
  } do
    schedule = due!(actor)
    {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    assert 1 = ScheduleOccurrences.start!(actor, occurrence.id, "exec_1")
    assert 0 = ScheduleOccurrences.start!(actor, occurrence.id, "exec_2")

    assert {:ok, %{state: "started", execution_id: "exec_1", attempts: 1}} =
             ScheduleOccurrences.get(actor, occurrence.id)

    assert {:ok, "uncertain"} =
             ScheduleOccurrences.settle_dead(actor, occurrence.id)

    assert {:ok, nil} = ScheduleOccurrences.settle_dead(actor, occurrence.id)

    assert {:ok, 0} =
             ScheduleOccurrences.finish(actor, occurrence.id, "completed")

    # A claimed one nothing invoked fails when its runner dies.
    later = due!(actor)
    {:ok, claimed} = ScheduleOccurrences.claim(later, "node-a", next_occurrence())

    assert {:ok, "failed"} =
             ScheduleOccurrences.settle_dead(actor, claimed.id)

    # Another estate reads none of it.
    assert {:error, :not_found} =
             ScheduleOccurrences.get(
               %{actor | athanor_id: "ath_elsewhere"},
               occurrence.id
             )
  end

  test "recovery names what a dead scheduler left: claimed never invoked, started with its execution gone",
       %{actor: actor} do
    schedule = due!(actor)
    {:ok, claimed} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    running = due!(actor)
    {:ok, started} = ScheduleOccurrences.claim(running, "node-a", next_occurrence())

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_live",
          reference: "reagent:local.test:1.0.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "reagent",
          schedule_id: running.id
        },
        occurrence_id: started.id,
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    # Still running: not recoverable.
    assert {:ok, %{never_invoked: [%{id: claimed_id}], lapsed: []}} =
             ScheduleOccurrences.recoverable(now())

    assert claimed_id == claimed.id

    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        "exec_live",
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "swept"},
        attempt.attempt,
        Arca.Test.Actor.stored()
      )

    assert {:ok, %{lapsed: [%{id: started_id}]}} = ScheduleOccurrences.recoverable(now())
    assert started_id == started.id
  end

  test "a live member's freshly claimed occurrence is nobody else's to recover", %{actor: actor} do
    member = "node-live-#{System.unique_integer([:positive])}"
    boot = member <> "#boot_a"
    assert {:ok, _} = Arca.ControlPlane.take(member, boot, 60_000)

    schedule = due!(actor)
    {:ok, fresh} = ScheduleOccurrences.claim(schedule, boot, next_occurrence())

    # The cutoff is behind the claim, and the claimant is on the roster:
    # the occurrence is that member's work in hand.
    cutoff = DateTime.add(now(), -60_000, :millisecond)
    assert {:ok, %{never_invoked: never_invoked}} = ScheduleOccurrences.recoverable(cutoff)
    refute fresh.id in Enum.map(never_invoked, & &1.id)

    # The member drops out of the cell, and the same row is recoverable
    # without the cutoff moving at all.
    expire(member)
    assert {:ok, %{never_invoked: never_invoked}} = ScheduleOccurrences.recoverable(cutoff)
    assert fresh.id in Enum.map(never_invoked, & &1.id)
  end

  test "a claimant still on the roster but past the cutoff is recoverable", %{actor: actor} do
    member = "node-stuck-#{System.unique_integer([:positive])}"
    boot = member <> "#boot_a"
    assert {:ok, _} = Arca.ControlPlane.take(member, boot, 60_000)

    schedule = due!(actor)
    {:ok, stuck} = ScheduleOccurrences.claim(schedule, boot, next_occurrence())

    assert {:ok, %{never_invoked: never_invoked}} =
             ScheduleOccurrences.recoverable(DateTime.add(now(), 1_000, :millisecond))

    assert stuck.id in Enum.map(never_invoked, & &1.id)
  end

  test "of two recoverers of one abandoned occurrence, exactly one re-runs it", %{actor: actor} do
    schedule = due!(actor)
    {:ok, abandoned} = ScheduleOccurrences.claim(schedule, "boot-gone", next_occurrence())

    # Both read the same row and both take it from the same claimant; the
    # statement names the claimant it was read under, so the second
    # matches nothing.
    assert :ok = ScheduleOccurrences.recover(actor, abandoned.id, "boot-gone", "boot-a")
    assert :held = ScheduleOccurrences.recover(actor, abandoned.id, "boot-gone", "boot-b")

    assert {:ok, %{claimed_by: "boot-a", state: "claimed"} = row} =
             ScheduleOccurrences.get(actor, abandoned.id)

    # And the winner's own claim is fresh, so the next pass does not take
    # it away again.
    assert DateTime.compare(row.claimed_at, abandoned.claimed_at) != :lt

    # A started occurrence is not re-run by this door at all.
    assert 1 = ScheduleOccurrences.start!(actor, abandoned.id, "exec_started")
    assert :held = ScheduleOccurrences.recover(actor, abandoned.id, "boot-a", "boot-c")

    # Nor is another estate's.
    assert :held =
             ScheduleOccurrences.recover(
               %{actor | athanor_id: "ath_elsewhere"},
               abandoned.id,
               "boot-a",
               "boot-c"
             )
  end

  test "an execution admitted for an occurrence nobody claimed is refused", %{actor: actor} do
    schedule = due!(actor)
    {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())
    assert 1 = ScheduleOccurrences.start!(actor, occurrence.id, "exec_first")

    assert {:error, :occurrence_not_claimed} =
             Arca.Execution.admit(
               %{
                 id: "exec_second",
                 reference: "reagent:local.test:1.0.0",
                 user_id: actor.user_id,
                 athanor_id: actor.athanor_id,
                 component_type: "reagent",
                 schedule_id: schedule.id
               },
               occurrence_id: occurrence.id,
               grant: Arca.Test.Actor.grant(actor.athanor_id),
               verify: &Arca.Test.Actor.admits/1
             )

    assert Arca.Repo.get(Arca.Execution, "exec_second") == nil
  end
end
