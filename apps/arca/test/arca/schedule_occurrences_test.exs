# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ScheduleOccurrencesTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow

  # Taking a cell slot for a stand-in member writes this VM's one standing
  # record, which every gate in the suite reads: each case puts back what
  # it found rather than deciding another file's run.
  @standing_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

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
        actor,
        Map.merge(
          %{
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            name: "occ-#{System.unique_integer([:positive])}",
            cron_expression: "0 * * * *",
            reference: "reagent:local.test:1.0.0",
            resolved_reference: "reagent:local.test:1.0.0",
            profile_id: "prof_test",
            cap: 1_000
          },
          attrs
        )
      )

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  # The cursor of an existing schedule, moved back so its next occurrence is due.
  defp due_again!(%{id: _} = schedule) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
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

  # The occurrence's claim older than any cutoff the cases read with.
  defp age_claim!(id) do
    {1, _} =
      Arca.Repo.update_all(
        from(o in Arca.Schemas.ScheduleOccurrence, where: o.id == ^id),
        set: [claimed_at: DateTime.add(now(), -120, :second)]
      )

    :ok
  end

  defp cursor!(id) do
    {:ok, row} = CronSchedule.get_for_daemon(id)
    row.next_run_at
  end

  # A feed bound under the member's slot, its first occurrence due.
  defp due_feed!(actor) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => "feed-#{System.unique_integer([:positive])}",
        "label" => "A feed",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    {:ok, feed} =
      CronSchedule.create_feed(actor, %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_test",
        cap: 10
      })

    due_again!(feed)
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot, whatever the build's own configuration says; the switch is put
  # back when the case ends, as the standing record is by `setup`.
  defp claimant! do
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-occ-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over in the database; this member's cached
  # standing is left as it was.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
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
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
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
                 "node-a",
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

    assert {:ok, 1} =
             ScheduleOccurrences.finish(actor, open.id, "node-a", open.execution_id, "completed")

    assert {:ok, %{state: "claimed"}} =
             ScheduleOccurrences.claim(forbid, "node-a", next_occurrence())
  end

  test "the claim decides on the row's concurrency, never on the caller's copy", %{actor: actor} do
    forbid = due!(actor, %{concurrency: "forbid"})
    {:ok, open} = ScheduleOccurrences.claim(forbid, "node-a", next_occurrence())
    assert 1 = ScheduleOccurrences.start!(actor, open.id, "node-a", "exec_#{open.id}")

    # A stale or forged copy that says `allow` is read for its id, its
    # athanor and the cursor it saw; the row still forbids an overlap.
    forged = %{due_again!(forbid) | concurrency: "allow"}
    assert :overlapping = ScheduleOccurrences.claim(forged, "node-a", next_occurrence())
    assert {:ok, [_only]} = ScheduleOccurrences.list(actor, forbid.id)
  end

  test "start moves a claimed occurrence once; finish and settle_dead end it as the row says", %{
    actor: actor
  } do
    schedule = due!(actor)
    {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    assert 1 = ScheduleOccurrences.start!(actor, occurrence.id, "node-a", "exec_1")
    assert 0 = ScheduleOccurrences.start!(actor, occurrence.id, "node-a", "exec_2")

    assert {:ok, %{state: "started", execution_id: "exec_1", attempts: 1}} =
             ScheduleOccurrences.get(actor, occurrence.id)

    # A started occurrence is its claimant's under its execution: another
    # claimant, another execution or none moves nothing.
    for {claimed_by, execution_id} <- [
          {"node-b", "exec_1"},
          {"node-a", "exec_2"},
          {"node-a", nil}
        ] do
      assert {:error, :stale} =
               ScheduleOccurrences.settle_dead(actor, occurrence.id, claimed_by, execution_id)

      assert {:error, :stale} =
               ScheduleOccurrences.finish(
                 actor,
                 occurrence.id,
                 claimed_by,
                 execution_id,
                 "completed"
               )
    end

    assert {:ok, %{state: "started"}} = ScheduleOccurrences.get(actor, occurrence.id)

    assert {:ok, "uncertain"} =
             ScheduleOccurrences.settle_dead(actor, occurrence.id, "node-a", "exec_1")

    # Ended, it is nobody's to end again.
    assert {:error, :stale} =
             ScheduleOccurrences.settle_dead(actor, occurrence.id, "node-a", "exec_1")

    assert {:error, :stale} =
             ScheduleOccurrences.finish(actor, occurrence.id, "node-a", "exec_1", "completed")

    assert {:ok, %{state: "uncertain"}} = ScheduleOccurrences.get(actor, occurrence.id)

    # A claimed one nothing invoked fails when its runner dies, whether the
    # runner names the execution it would have started or none; only its
    # own claimant ends it.
    later = due!(actor)
    {:ok, claimed} = ScheduleOccurrences.claim(later, "node-a", next_occurrence())

    assert {:error, :stale} =
             ScheduleOccurrences.settle_dead(actor, claimed.id, "node-b", "exec_3")

    assert {:ok, "failed"} =
             ScheduleOccurrences.settle_dead(actor, claimed.id, "node-a", "exec_3")

    # And a finish naming no execution ends only one never started.
    last = due!(actor)
    {:ok, unstarted} = ScheduleOccurrences.claim(last, "node-a", next_occurrence())

    assert {:ok, 1} =
             ScheduleOccurrences.finish(actor, unstarted.id, "node-a", nil, "failed")

    assert {:ok, %{state: "failed", execution_id: nil}} =
             ScheduleOccurrences.get(actor, unstarted.id)

    # Another athanor reads none of it.
    assert {:error, :not_found} =
             ScheduleOccurrences.get(
               %{actor | athanor_id: "ath_elsewhere"},
               occurrence.id
             )
  end

  test "start! moves only the claimant's own occurrence: another claimant moves nothing", %{
    actor: actor
  } do
    schedule = due!(actor)
    {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    assert 0 = ScheduleOccurrences.start!(actor, occurrence.id, "node-b", "exec_other")

    assert {:ok, %{state: "claimed", claimed_by: "node-a", execution_id: nil, attempts: 0}} =
             ScheduleOccurrences.get(actor, occurrence.id)

    assert 1 = ScheduleOccurrences.start!(actor, occurrence.id, "node-a", "exec_own")

    assert {:ok, %{state: "started", execution_id: "exec_own", attempts: 1}} =
             ScheduleOccurrences.get(actor, occurrence.id)
  end

  test "a finish naming no claimant ends only an occurrence that names none", %{actor: actor} do
    schedule = due!(actor)
    {:ok, claimed} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    # A row with a claimant is not one that names none: nothing moves.
    assert {:error, :stale} = ScheduleOccurrences.finish(actor, claimed.id, nil, nil, "failed")

    assert {:ok, %{state: "claimed", claimed_by: "node-a", ended_at: nil}} =
             ScheduleOccurrences.get(actor, claimed.id)

    # A row that names none, as `recoverable/1` reads one, is ended by it.
    unclaimed =
      Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
        id: Prima.UUID7.generate_id("occ"),
        athanor_id: actor.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(DateTime.utc_now(), -3_600, :second),
        state: "claimed",
        claimed_by: nil,
        claimed_at: now()
      })

    assert {:ok, 1} = ScheduleOccurrences.finish(actor, unclaimed.id, nil, nil, "failed")

    assert {:ok, %{state: "failed", claimed_by: nil}} =
             ScheduleOccurrences.get(actor, unclaimed.id)

    assert {:ok, %{state: "claimed"}} = ScheduleOccurrences.get(actor, claimed.id)
  end

  test "recovery names what a dead scheduler left: claimed never invoked, started with its execution gone",
       %{actor: actor} do
    schedule = due!(actor)
    {:ok, claimed} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())

    # Admission starts only the admitting boot's claim.
    running = due!(actor)
    {:ok, started} = ScheduleOccurrences.claim(running, Prima.Boot.id(), next_occurrence())

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_live",
          reference: "reagent:local.test:1.0.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "reagent",
          schedule_id: running.id,
          origin: :schedule
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

  test "a started occurrence whose execution ended is answered by whose it is, whatever its member's clock wrote",
       %{actor: actor} do
    # This boot holds a live slot, so what it claims is a live member's.
    member = "node-ending-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Arca.ControlPlane.take(member, Prima.Boot.id(), 60_000)

    schedule = due!(actor)
    {:ok, started} = ScheduleOccurrences.claim(schedule, Prima.Boot.id(), next_occurrence())

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_ending",
          reference: "reagent:local.test:1.0.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "reagent",
          schedule_id: schedule.id,
          origin: :schedule
        },
        occurrence_id: started.id,
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
      )

    # The run has gone on past the cutoff, so its claim is abandoned by age.
    age_claim!(started.id)
    cutoff = DateTime.add(now(), -60_000, :millisecond)

    answered = fn ->
      {:ok, %{lapsed: lapsed, lapsed_live: live}} = ScheduleOccurrences.recoverable(cutoff)
      {started.id in Enum.map(lapsed, & &1.id), started.id in Enum.map(live, & &1.id)}
    end

    # Running: neither.
    assert answered.() == {false, false}

    # Ended, its member's wall clock a minute behind the cell's: a live
    # member's, for the caller to grace, never ended at once.
    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        "exec_ending",
        "completed",
        %{completed_at: DateTime.add(DateTime.utc_now(), -61, :second), duration_ms: 1},
        attempt.attempt,
        Arca.Test.Actor.stored()
      )

    assert answered.() == {false, true}

    # Its member's clock an hour ahead, or no end time recorded: the same.
    for written <- [DateTime.add(DateTime.utc_now(), 3_600, :second), nil] do
      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == "exec_ending"),
          set: [completed_at: written]
        )

      assert answered.() == {false, true}
    end

    # Its claimant no live member: lapsed, to be ended now.
    expire(member)
    assert answered.() == {true, false}
  end

  test "a started occurrence whose execution row is gone is answered by whose it is", %{
    actor: actor
  } do
    member = "node-orphan-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Arca.ControlPlane.take(member, Prima.Boot.id(), 60_000)
    schedule = due!(actor)
    {:ok, orphan} = ScheduleOccurrences.claim(schedule, Prima.Boot.id(), next_occurrence())

    {1, _} =
      Arca.Repo.update_all(
        from(o in Arca.Schemas.ScheduleOccurrence, where: o.id == ^orphan.id),
        set: [state: "started", execution_id: "exec_gone"]
      )

    age_claim!(orphan.id)
    cutoff = DateTime.add(now(), -60_000, :millisecond)

    {:ok, %{lapsed: lapsed, lapsed_live: live}} = ScheduleOccurrences.recoverable(cutoff)
    refute orphan.id in Enum.map(lapsed, & &1.id)
    assert orphan.id in Enum.map(live, & &1.id)

    expire(member)
    {:ok, %{lapsed: lapsed, lapsed_live: live}} = ScheduleOccurrences.recoverable(cutoff)
    assert orphan.id in Enum.map(lapsed, & &1.id)
    refute orphan.id in Enum.map(live, & &1.id)
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
    assert 1 = ScheduleOccurrences.start!(actor, abandoned.id, "boot-a", "exec_started")
    assert :held = ScheduleOccurrences.recover(actor, abandoned.id, "boot-a", "boot-c")

    # Nor is another athanor's.
    assert :held =
             ScheduleOccurrences.recover(
               %{actor | athanor_id: "ath_elsewhere"},
               abandoned.id,
               "boot-a",
               "boot-c"
             )
  end

  describe "the claim's slot fence" do
    test "a schedule's and a feed's claim are refused :not_owner after a takeover, nothing moved",
         %{actor: actor} do
      slot = claimant!()
      feed = due_feed!(actor)
      schedule = due!(actor)
      before = for row <- [feed, schedule], do: CronSchedule.get_for_daemon(row.id)

      # A successor takes the slot over; this member's cached standing
      # still says it holds it, so only the claim's own check stands
      # between it and the row, whatever the row's kind.
      take_over!(slot)
      assert Arca.ControlPlane.held?()

      for row <- [feed, schedule] do
        assert {:error, :not_owner} =
                 ScheduleOccurrences.claim(row, "boot-stale", next_occurrence())

        assert {:ok, []} = ScheduleOccurrences.list(actor, row.id)
      end

      assert before == for(row <- [feed, schedule], do: CronSchedule.get_for_daemon(row.id))
    end

    test "a schedule and a feed are claimed while the member holds its slot", %{actor: actor} do
      claimant!()

      for row <- [due_feed!(actor), due!(actor)] do
        advanced_to = next_occurrence()

        assert {:ok, %{state: "claimed", claimed_by: "boot-live"}} =
                 ScheduleOccurrences.claim(row, "boot-live", advanced_to)

        assert DateTime.compare(cursor!(row.id), advanced_to) == :eq
        assert :held = ScheduleOccurrences.claim(row, "boot-other", next_occurrence())
      end
    end
  end

  test "an execution admitted for an occurrence nobody claimed is refused", %{actor: actor} do
    schedule = due!(actor)
    {:ok, occurrence} = ScheduleOccurrences.claim(schedule, "node-a", next_occurrence())
    assert 1 = ScheduleOccurrences.start!(actor, occurrence.id, "node-a", "exec_first")

    assert {:error, :occurrence_not_claimed} =
             Arca.Execution.admit(
               %{
                 id: "exec_second",
                 reference: "reagent:local.test:1.0.0",
                 user_id: actor.user_id,
                 athanor_id: actor.athanor_id,
                 component_type: "reagent",
                 schedule_id: schedule.id,
                 origin: :schedule
               },
               occurrence_id: occurrence.id,
               grant: Arca.Test.Actor.grant(actor.athanor_id),
               verify: &Arca.Test.Actor.admits/1
             )

    assert Arca.Repo.get(Arca.Schemas.Execution, "exec_second") == nil
  end
end

defmodule Arca.ScheduleOccurrencesTakeoverTest do
  @moduledoc """
  A stale member's writes to an occurrence, in the sequence that makes one
  stale with no clock drift and no edit to the lease row: the member's
  cached standing passes, its write waits, its lease runs out on the
  cell's clock, a successor takes the slot through
  `Arca.ControlPlane.take/3`, and only then does the write go on.

  The writes run on connections of their own, outside the sandbox. On
  PostgreSQL the write really waits, on a row lock another transaction
  holds across the expiry and the takeover. SQLite's one write lock would
  hold the successor's take behind that transaction too, so there the
  takeover commits first and the write runs while this member's cached
  standing still says it holds the slot: the same divergence between the
  cache and the row. Either way the member's cached standing is held
  throughout, so what refuses the write is the database. Each case works
  in an athanor of its own, whose rows it deletes when it ends.
  """

  # Writes the process-wide standing record and the claimant switch, and
  # holds rows locked across connections; each case restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.{CellLease, ScheduleOccurrence}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  # Short enough to run out while the case waits; the setup is done under
  # a long lease, which the member then renews to this.
  @lease_ms 300

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    athanor = "ath_occ_fence_#{System.unique_integer([:positive])}"
    node = "node-occ-fence-#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(o in ScheduleOccurrence, where: o.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(s in ScheduleRow, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
      end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    # A claimant runs, as a deployment's does, and this member holds its
    # slot under a lease long enough for the case's own setup.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot_a", 60_000) end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), slot: slot}
  end

  test "an ordinary schedule's claim after a takeover is refused :not_owner, with nothing moved",
       %{actor: actor, slot: slot} do
    schedule = unboxed(fn -> due!(actor) end)
    before = unboxed(fn -> CronSchedule.get_for_daemon(schedule.id) end)

    answer =
      stale_write(slot, lock_schedule(schedule.id), fn ->
        ScheduleOccurrences.claim(schedule, slot.owner, next_occurrence())
      end)

    assert answer == {:error, :not_owner}
    assert unboxed(fn -> CronSchedule.get_for_daemon(schedule.id) end) == before
    assert {:ok, []} = unboxed(fn -> ScheduleOccurrences.list(actor, schedule.id) end)
  end

  for writer <- [:finish, :settle_dead] do
    test "an old member's late #{writer}, after a successor recovered and started the occurrence, is :stale",
         %{actor: actor, slot: slot} do
      schedule = unboxed(fn -> due!(actor) end)

      {:ok, occurrence} =
        unboxed(fn -> ScheduleOccurrences.claim(schedule, slot.owner, next_occurrence()) end)

      successor = slot.node <> "#boot_b"

      # What the successor does once it holds the slot: it takes the
      # abandoned claim, and its execution's admission starts it.
      recovered_and_started = fn ->
        :ok = ScheduleOccurrences.recover(actor, occurrence.id, slot.owner, successor)
        1 = ScheduleOccurrences.start!(actor, occurrence.id, successor, "exec_successor")
      end

      # The old member's late callback names its own claim and the
      # execution it minted for the run.
      answer =
        stale_write(
          slot,
          lock_occurrence(occurrence.id),
          fn -> late(unquote(writer), actor, occurrence.id, slot.owner, "exec_old") end,
          recovered_and_started
        )

      assert answer == {:error, :stale}

      assert {:ok, %{state: "started", claimed_by: ^successor, execution_id: "exec_successor"}} =
               unboxed(fn -> ScheduleOccurrences.get(actor, occurrence.id) end)
    end
  end

  defp late(:finish, actor, id, claimed_by, execution_id),
    do: ScheduleOccurrences.finish(actor, id, claimed_by, execution_id, "failed")

  defp late(:settle_dead, actor, id, claimed_by, execution_id),
    do: ScheduleOccurrences.settle_dead(actor, id, claimed_by, execution_id)

  defp due!(actor) do
    {:ok, schedule} =
      CronSchedule.create(actor, %{
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        name: "occ-fence-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: "prof_test",
        cap: 1_000
      })

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp next_occurrence, do: DateTime.add(DateTime.utc_now(), 300, :second)

  defp lock_schedule(id) do
    fn ->
      from(s in ScheduleRow, where: s.id == ^id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()
    end
  end

  defp lock_occurrence(id) do
    fn ->
      from(o in ScheduleOccurrence, where: o.id == ^id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()
    end
  end

  # ---- the stale write ---------------------------------------------------------

  # The member's cached standing passes, `write` waits, the lease runs out
  # and a successor takes the slot, then `write` goes on. On PostgreSQL it
  # waits on `lock`, held by a transaction that runs `then` once the
  # takeover has committed and commits after it; on SQLite the takeover
  # and `then` commit first. Answers what `write` answered.
  defp stale_write(slot, lock, write, then \\ fn -> :ok end) do
    slot = expiring!(slot)
    assert ControlPlane.held?()
    test = self()

    if postgres?() do
      holder = holding(lock)

      writer =
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:backend, backend_pid()})
            write.()
          end)
        end)

      assert_receive {:backend, backend}, 15_000
      LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
      taken_over!(slot)
      release(holder, then)
      Task.await(writer, 30_000)
    else
      taken_over!(slot)
      unboxed(then)
      unboxed(write)
    end
  end

  # The member renews to a short lease, a write of its own, and its
  # cached standing is held whatever the lease then does.
  defp expiring!(slot) do
    {:ok, renewed} = unboxed(fn -> ControlPlane.renew(@lease_ms) end)
    assert renewed.generation == slot.generation
    hold_cached(renewed)
    renewed
  end

  defp hold_cached(slot) do
    ControlPlane.record_slot(slot)
    ControlPlane.record_generation(slot.generation)
    ControlPlane.record({:held, 60_000})
  end

  # The lease runs out on the cell's clock with no edit to its row, and a
  # successor takes the slot over through `take/3`. `take/3` records what
  # it won in this VM's standing; the successor is another member, so this
  # member's own standing is put back.
  defp taken_over!(slot) do
    await_expiry(slot.node)

    assert {:ok, %{generation: generation}} =
             unboxed(fn -> ControlPlane.take(slot.node, slot.node <> "#boot_b", 60_000) end)

    assert generation == slot.generation + 1
    hold_cached(slot)
  end

  defp await_expiry(node, tries \\ 500)
  defp await_expiry(_node, 0), do: flunk("the member's lease never ran out")

  defp await_expiry(node, tries) do
    expired? =
      unboxed(fn ->
        {:ok, %{lease_until: lease_until}} = ControlPlane.slot(node)
        DateTime.compare(lease_until, Arca.ServerMetaStorage.now!()) != :gt
      end)

    unless expired? do
      Process.sleep(20)
      await_expiry(node, tries - 1)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # Run `lock` in a transaction of its own and hold it open until
  # `release/2`, which runs its `then` in that transaction before it
  # commits.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            lock.()
            send(test, {:holding, self()})

            receive do
              {:commit, then} -> then.()
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task, then) do
    send(task.pid, {:commit, then})
    assert {:ok, _} = Task.await(task, 30_000)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end
end
