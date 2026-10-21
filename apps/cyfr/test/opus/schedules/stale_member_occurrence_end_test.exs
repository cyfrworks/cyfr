# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.StaleMemberOccurrenceEndTest do
  @moduledoc """
  An occurrence's end is the slot holder's: ARCHITECTURE.md §6.3 has each
  fenced writer verify its live slot in its writing transaction, and §6.1
  a stale owner emit no result. The occurrence's finish and a dead runner's
  settlement (`Arca.ScheduleOccurrences.finish/6`, `settle_dead/4`) lock
  the occurrence's row and check the member's slot under it, in the
  transaction that would write the terminal state and the outcome's
  record, so a member whose slot a successor took over ends nothing,
  records nothing and is told `{:error, :not_owner}` — while its cached
  standing still says it holds the slot, as the scheduler's own gates
  read it. A stale member's recovery (`recover/4`) moves only the claim:
  no end under it lands, and the successor's end stands.
  """

  # Writes the process-wide standing record and the claimant switch; each
  # case restores them.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  # A refused end is logged by the scheduler, as it should be.
  @moduletag :capture_log

  alias Arca.{ControlPlane, CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Opus.Schedules.Scheduler

  @keys [
    {ControlPlane, :standing},
    {ControlPlane, :generation},
    {ControlPlane, :slot}
  ]

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()
    ctx = Sanctum.TestContext.local()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  describe "an occurrence's end under the member's live slot" do
    setup %{ctx: ctx, actor: actor} do
      slot = claimant!()
      schedule = ctx |> create_schedule() |> due!()
      {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
      boot = Prima.Boot.id()

      # Claimed while the slot is this member's, as the scheduler claims.
      assert {:ok, occurrence} = ScheduleOccurrences.claim(row, boot, cadence())
      assert [%{state: "claimed", claimed_by: ^boot}] = occurrences(actor, schedule.id)

      # A successor takes the slot over; this member's cached standing
      # still says it holds it.
      :ok = take_over!(slot)
      assert ControlPlane.held?()

      # Control: the schedule row's writer is refused by the slot fence.
      assert {:error, :not_owner} = CronSchedule.record_run(actor, schedule.id, "exec_control")

      {:ok, schedule: row, occurrence: occurrence, boot: boot, slot: slot}
    end

    test "the finish moves nothing and runs no outcome closure", %{
      actor: actor,
      schedule: schedule,
      occurrence: occurrence,
      boot: boot
    } do
      test = self()

      assert {:error, :not_owner} =
               ScheduleOccurrences.finish(actor, occurrence.id, boot, nil, "completed",
                 also: fn _finished ->
                   send(test, :also_ran)
                   :ok
                 end
               )

      refute_received :also_ran

      assert [%{state: "claimed", claimed_by: ^boot, ended_at: nil}] =
               occurrences(actor, schedule.id)
    end

    test "a dead runner's settlement moves nothing", %{
      actor: actor,
      schedule: schedule,
      occurrence: occurrence,
      boot: boot
    } do
      assert {:error, :not_owner} =
               ScheduleOccurrences.settle_dead(actor, occurrence.id, boot, "exec_dead")

      assert [%{state: "claimed", claimed_by: ^boot, ended_at: nil}] =
               occurrences(actor, schedule.id)
    end

    test "the scheduler's completion records no outcome and leaves the occurrence open", %{
      actor: actor,
      schedule: schedule,
      occurrence: occurrence,
      boot: boot
    } do
      assert {:error, :not_owner} =
               Scheduler.complete(schedule, occurrence, "exec_done", %{"ran" => true})

      assert [%{state: "claimed", claimed_by: ^boot, ended_at: nil}] =
               occurrences(actor, schedule.id)

      assert outcomes(occurrence.id) == []
    end

    test "a stale member's recovery moves only the claim: it ends nothing under it, and the successor's end stands",
         %{actor: actor, occurrence: occurrence, boot: boot, slot: slot} do
      # Recovery is not an end: the stale member can move the claim ...
      assert :ok = ScheduleOccurrences.recover(actor, occurrence.id, boot, "stale-recoverer")

      assert {:ok, %{state: "claimed", claimed_by: "stale-recoverer", ended_at: nil}} =
               ScheduleOccurrences.get(actor, occurrence.id)

      # ... but ends nothing under it and files no outcome.
      assert {:error, :not_owner} =
               ScheduleOccurrences.finish(
                 actor,
                 occurrence.id,
                 "stale-recoverer",
                 nil,
                 "completed"
               )

      assert {:error, :not_owner} =
               ScheduleOccurrences.settle_dead(actor, occurrence.id, "stale-recoverer", nil)

      assert outcomes(occurrence.id) == []

      # The successor, holding the slot, recovers the claim and ends it ...
      successor = %{slot | owner: slot.node <> "#boot_b", generation: slot.generation + 1}
      ControlPlane.record_slot(successor)
      ControlPlane.record_generation(successor.generation)

      assert :ok =
               ScheduleOccurrences.recover(
                 actor,
                 occurrence.id,
                 "stale-recoverer",
                 successor.owner
               )

      assert {:ok, 1} =
               ScheduleOccurrences.finish(actor, occurrence.id, successor.owner, nil, "completed")

      # ... and a later recovery by the stale member cannot take the ended row.
      ControlPlane.record_slot(slot)
      ControlPlane.record_generation(slot.generation)
      assert :held = ScheduleOccurrences.recover(actor, occurrence.id, successor.owner, boot)

      owner = successor.owner

      assert {:ok, %{state: "completed", claimed_by: ^owner}} =
               ScheduleOccurrences.get(actor, occurrence.id)
    end
  end

  # The outcome records filed for one occurrence.
  defp outcomes(occurrence_id) do
    Arca.Repo.all(
      from(r in Arca.Schemas.OutboxRecord,
        where: r.source_kind == "schedule_occurrence" and r.source_id == ^occurrence_id
      )
    )
  end

  defp create_schedule(ctx) do
    {:ok, schedule} =
      CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "end-fence-#{System.unique_integer([:positive])}",
        cron_expression: "30 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: "prof_test",
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cap: 1_000
      })

    schedule
  end

  # Due five seconds ago: within the missed bound, an ordinary occurrence.
  defp due!(schedule) do
    past = DateTime.add(DateTime.utc_now(), -5, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp cadence do
    %{
      next_after: fn at -> {:ok, DateTime.add(at, 3600, :second)} end,
      missed_bound_ms: 60_000
    }
  end

  defp occurrences(actor, schedule_id) do
    {:ok, rows} = ScheduleOccurrences.list(actor, schedule_id)
    rows
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none. Restored when the
  # case ends, registered before anything changes.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-end-fence-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor boot takes the member's row over, as a takeover past the
  # lease does; this member's cached standing does not hear of it.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end
end
