# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.OwnershipFenceTest do
  @moduledoc """
  What the scheduler does when a write's own check finds the occurrence is
  no longer this member's, while its cached standing still says it is.

  A claim or an admission refused `:not_owner` was refused by the
  database, in the write's own transaction: the occurrence is left to
  recovery, with nothing written and no error recorded. A finish or a
  dead runner's settlement answered `:stale` found the occurrence another
  member's now: the decision this member opened is closed with the run's
  answer, and nothing else is written. A finish refused `:not_owner` found
  this member's slot taken over, in the finish's own transaction: the
  occurrence is not ended and no outcome is recorded, the decision is
  closed with the run's answer, no run is recorded on the schedule, and
  the occurrence is left to recovery.

  The fires run through the real scheduler path with the scripted worker
  service the scheduler's own suite uses: everything but the component is
  real.
  """

  # Starts the scheduler, takes a slot through `Arca.ControlPlane` (the
  # process-wide standing record) and switches the claimant on for the
  # ownership cases; each restores what it changed.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Arca.Schemas.ScheduleOccurrence
  alias Opus.Schedules.Scheduler
  alias Cyfr.Bus.ScheduleCompleted
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.test"
  @profile_id "prof_test"

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  # The scheduler's recheck tick: a claim older than two of them is
  # abandoned whoever made it.
  @tick_ms 30_000

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "fence_#{System.unique_integer([:positive])}")
    keys = [cyfr: :cron_scheduler_enabled, cyfr: :locus_runtime_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)

    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers(@reference, prev[{:cyfr, :locus_runtime_workers}])
    )

    Application.put_env(:arca, :base_path, test_path)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    consented!(ctx)
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  test "a claim refused :not_owner defers to recovery, writing nothing and recording no error",
       %{ctx: ctx, actor: actor} do
    slot = claimant!()
    script!([%{"ran" => true}])
    watch_outcomes()
    schedule = due!(create_schedule(ctx))

    # A successor takes the slot over before the fire; this member's cached
    # standing still says it holds it, so the scheduler fires, and only the
    # claim's own check stands between it and the row.
    take_over!(slot)
    assert Arca.ControlPlane.held?()

    scheduler = scheduler!()

    # The fire was answered `:not_owner` and deferred, as a lost generation
    # defers: the schedule is looked at again later, and the deferral's own
    # pass, a tick away, fires before the one the start asked for.
    wait_until(fn -> deferred?(scheduler, schedule.id) end)
    state = :sys.get_state(scheduler)
    assert Process.read_timer(state.recovery_ref) <= @tick_ms

    assert occurrences(actor, schedule.id) == []
    assert {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
    assert DateTime.compare(row.next_run_at, schedule.next_run_at) == :eq
    assert %{run_count: 0, error_count: 0} = row
    assert ScriptedWorker.calls() == []
    assert fire_decisions() == []
    refute_received {:schedule_outcome, _}
  end

  test "an admission refused :not_owner leaves the claimed occurrence to recovery, writing nothing",
       %{ctx: ctx, actor: actor} do
    slot = claimant!()
    script!([%{"ran" => true}])
    watch_outcomes()
    schedule = due!(create_schedule(ctx))

    # The claim is made while the slot is this member's; the run is held
    # before its admission while a successor takes the slot over.
    :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)

    take_over!(slot)
    assert Arca.ControlPlane.held?()

    log =
      capture_log(fn ->
        :ok = :sys.resume(Opus.Schedules.TaskSupervisor)
        wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)
      end)

    # The admission's own transaction refused it: no execution, and the
    # occurrence is still the claim this member made, never invoked.
    boot = Prima.Boot.id()

    assert [%{state: "claimed", claimed_by: ^boot, execution_id: nil, attempts: 0}] =
             occurrences(actor, schedule.id)

    assert [] = Arca.Repo.all(Arca.Schemas.Execution)
    assert ScriptedWorker.calls() == []

    # Its own decision is closed with the refusal; no error is recorded and
    # no failure is announced.
    assert [%{completion: "failed", completion_class: "not_owner"}] = fire_decisions()
    assert {:ok, %{run_count: 0, error_count: 0}} = CronSchedule.get_for_daemon(schedule.id)
    refute_received {:schedule_outcome, _}
    assert log =~ "no longer owns its slot"
  end

  test "a finish answered :stale writes nothing further: the successor's occurrence is left running",
       %{ctx: ctx, actor: actor} do
    script!([%{"ran" => true}])
    watch_outcomes()
    schedule = due!(create_schedule(ctx))

    # This member claims the occurrence and its run is held before its
    # admission; meanwhile a successor recovers the claim and starts it.
    :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)
    [%{id: occurrence_id}] = occurrences(actor, schedule.id)

    assert :ok =
             ScheduleOccurrences.recover(actor, occurrence_id, Prima.Boot.id(), "boot-successor")

    assert 1 =
             ScheduleOccurrences.start!(actor, occurrence_id, "boot-successor", "exec_successor")

    log =
      capture_log(fn ->
        :ok = :sys.resume(Opus.Schedules.TaskSupervisor)
        wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)
      end)

    # This member's admission was refused, and its finish of the failure
    # matched nothing: the occurrence is the successor's, still running.
    assert [%{state: "started", claimed_by: "boot-successor", execution_id: "exec_successor"}] =
             occurrences(actor, schedule.id)

    assert ScriptedWorker.calls() == []

    # Its own decision is closed with the run's answer; nothing else is
    # written or announced.
    assert [%{completion: "failed"}] = fire_decisions()
    assert {:ok, %{run_count: 0, error_count: 0}} = CronSchedule.get_for_daemon(schedule.id)
    refute_received {:schedule_outcome, _}
    assert log =~ "stale"
  end

  test "a completion whose finish is :stale records no run and publishes nothing",
       %{ctx: ctx, actor: actor} do
    script!([{:probe, self()}, %{"ran" => true}])
    watch_outcomes()
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    schedule = due!(create_schedule(ctx))
    scheduler = scheduler!()
    assert_receive {:scripted_probe, worker, _execution_id}, 10_000
    _ = :sys.get_state(scheduler)
    [task] = running_tasks()
    ref = Process.monitor(task)

    # Recovery ends the occurrence while the run is in flight; the run
    # then completes, and its own finish matches nothing.
    [%{id: occurrence_id, state: "started"}] = occurrences(actor, schedule.id)

    {1, _} =
      Arca.Repo.update_all(from(o in ScheduleOccurrence, where: o.id == ^occurrence_id),
        set: [state: "uncertain", ended_at: DateTime.utc_now()]
      )

    log =
      capture_log(fn ->
        send(worker, :continue)
        assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
        _ = :sys.get_state(scheduler)
      end)

    # No run is recorded on the schedule's row and nothing is published or
    # announced; the closer's word stands.
    assert {:ok, %{run_count: 0, last_run_at: nil, last_execution_id: nil}} =
             CronSchedule.get_for_daemon(schedule.id)

    assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    refute_received %ScheduleCompleted{}
    refute_received {:schedule_outcome, _}

    # This member's own decision is still closed, with the run's answer.
    assert [%{completion: "succeeded"}] = fire_decisions()
    assert log =~ "stale"
  end

  test "a completion whose finish is refused :not_owner records no outcome and no run, and leaves the occurrence to recovery",
       %{ctx: ctx, actor: actor} do
    slot = claimant!(Prima.Boot.id())
    script!([{:probe, self()}, %{"ran" => true}])
    watch_outcomes()
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    schedule = due!(create_schedule(ctx))
    scheduler = scheduler!()
    assert_receive {:scripted_probe, worker, _execution_id}, 10_000
    _ = :sys.get_state(scheduler)
    [task] = running_tasks()
    ref = Process.monitor(task)

    # A successor takes the slot over while the run is in flight; this
    # member still believes it holds it, so only the finish's own check
    # refuses the end.
    take_over!(slot)
    assert Arca.ControlPlane.held?()
    released = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        send(worker, :continue)
        assert_receive {:DOWN, ^ref, :process, ^task, {:shutdown, :left_to_recovery}}, 10_000
        _ = :sys.get_state(scheduler)
      end)

    # Not ended, and no outcome filed for it: the occurrence is still this
    # member's started claim, for recovery to reach.
    boot = Prima.Boot.id()

    assert [%{id: occurrence_id, state: "started", claimed_by: ^boot, ended_at: nil}] =
             occurrences(actor, schedule.id)

    assert [] =
             Arca.Repo.all(
               from(r in Arca.Schemas.OutboxRecord,
                 where: r.source_kind == "schedule_occurrence" and r.source_id == ^occurrence_id
               )
             )

    # No run is recorded on the schedule's row and nothing is published or
    # announced; this member's own decision is closed with the run's answer.
    assert {:ok, %{run_count: 0, last_run_at: nil, last_execution_id: nil}} =
             CronSchedule.get_for_daemon(schedule.id)

    refute_received %ScheduleCompleted{}
    refute_received {:schedule_outcome, _}
    assert [%{completion: "succeeded"}] = fire_decisions()
    assert log =~ "no longer owns its slot"

    state = :sys.get_state(scheduler)
    assert is_reference(state.recovery_ref)
    assert state.recovery_due >= due_after(released)
  end

  test "a dead runner whose occurrence another closer ended writes nothing",
       %{ctx: ctx, actor: actor} do
    script!([{:probe, self()}, %{"ran" => true}])
    watch_outcomes()
    schedule = due!(create_schedule(ctx))
    scheduler = scheduler!()
    assert_receive {:scripted_probe, _worker, _execution_id}, 10_000
    _ = :sys.get_state(scheduler)
    [task] = running_tasks()
    ref = Process.monitor(task)

    # Recovery ends the occurrence while the run is in flight, and then the
    # runner dies: its settlement matches nothing.
    [%{id: occurrence_id, state: "started"}] = occurrences(actor, schedule.id)

    {1, _} =
      Arca.Repo.update_all(from(o in ScheduleOccurrence, where: o.id == ^occurrence_id),
        set: [state: "uncertain", ended_at: DateTime.utc_now()]
      )

    log =
      capture_log(fn ->
        Process.exit(task, :kill)
        assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
        _ = :sys.get_state(scheduler)
      end)

    assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    assert {:ok, %{run_count: 0, error_count: 0}} = CronSchedule.get_for_daemon(schedule.id)
    assert log =~ "stale"
  end

  describe "an occurrence a live member left to recovery" do
    test "is reached by a pass due two ticks after the exit, though every later fire overlaps",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}, %{"ran" => true}])
      {scheduler, schedule, occurrence_id, released, state} = stuck!(ctx, actor)

      # One timer is armed: the overlap's own pass, a tick away, which
      # fires first, while the due the exit asked for, two ticks after the
      # run was let go and so after its claim, is the one recorded.
      assert is_reference(state.recovery_ref)
      assert Process.read_timer(state.recovery_ref) <= @tick_ms
      assert state.recovery_due >= due_after(released)

      # The claim aged two ticks and the pass delivered: it is recovered
      # and runs, as the execution its re-run admitted.
      recovered!(scheduler, actor, schedule, occurrence_id)

      assert [%{execution_id: execution_id}] =
               Enum.filter(occurrences(actor, schedule.id), &(&1.id == occurrence_id))

      assert execution_id in Enum.map(ScriptedWorker.calls(), & &1.execution_id)
      settled!(scheduler, actor, schedule)
    end

    test "the schedule's next fire, once it is recovered, claims and runs a new occurrence",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}, %{"ran" => true}])
      {scheduler, schedule, occurrence_id, _released, state} = stuck!(ctx, actor)
      assert is_reference(state.recovery_ref)
      recovered!(scheduler, actor, schedule, occurrence_id)

      # The overlap left the cursor due, so the schedule's own next fire
      # comes as soon as the recovered run ends: it claims a new
      # occurrence and runs it, and the cursor moves on.
      settled!(scheduler, actor, schedule)

      assert [%{id: next_id, state: "completed"}, %{id: ^occurrence_id, state: "completed"}] =
               occurrences(actor, schedule.id)

      assert next_id != occurrence_id
      assert [_, _] = ScriptedWorker.calls()
      assert {:ok, %{next_run_at: next_run}} = CronSchedule.get_for_daemon(schedule.id)
      assert DateTime.compare(next_run, DateTime.utc_now()) == :gt
    end

    test "a run whose answer comes after the cached standing ran out asks for a pass, though the standing is back when its exit is seen",
         %{ctx: ctx, actor: actor} do
      slot = claimant!()
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      _ = :sys.get_state(scheduler)
      [task] = running_tasks()
      ref = Process.monitor(task)

      # The run waits at the worker while this member's cached countdown
      # runs out, as it does when a renew comes late.
      Arca.ControlPlane.record({:held, 0})
      refute Arca.ControlPlane.held?()

      # The scheduler is held while the run answers, so it sees the exit
      # only after the late renew has put the standing back under the
      # same generation.
      :ok = :sys.suspend(scheduler)
      # Read the lower bound before releasing the run: recovery uses the
      # scheduler's clock when it handles the end, not this monitor's
      # observation of DOWN.
      released = System.monotonic_time(:millisecond)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 10_000
      Arca.ControlPlane.record({:held, 60_000})
      assert {:ok, slot.generation} == Arca.ControlPlane.generation()
      :ok = :sys.resume(scheduler)

      # The exit is seen as still ours, and still a pass is asked for, due
      # two ticks after it. The run's answer was written nowhere.
      state = :sys.get_state(scheduler)
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(released)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)
      assert {:ok, %{run_count: 0, error_count: 0}} = CronSchedule.get_for_daemon(schedule.id)
    end

    test "one timer serves both requests: the first pass re-arms for the later due it recorded",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}])
      slot = claimant!(Prima.Boot.id())

      # A `forbid` schedule held back by an open occurrence of this live
      # member's: its overlap asks for a pass a tick away.
      blocked = due!(create_schedule(ctx))
      boot = Prima.Boot.id()

      Arca.Repo.insert!(%ScheduleOccurrence{
        id: Prima.UUID7.generate_id("occ"),
        athanor_id: ctx.athanor_id,
        schedule_id: blocked.id,
        scheduled_for: DateTime.add(DateTime.utc_now(), -3_600, :second),
        state: "started",
        execution_id: "exec_elsewhere",
        attempts: 1,
        claimed_by: boot,
        claimed_at: Arca.ServerMetaStorage.now!()
      })

      stuck = create_schedule(ctx)
      scheduler = scheduler!()
      # The overlap's pass, a tick away, replaces the one the start asked
      # for two ticks away.
      wait_until(fn -> pass_within?(scheduler, @tick_ms) end)
      %{recovery_ref: first} = :sys.get_state(scheduler)

      # Then a run of another schedule is left to recovery, which asks for
      # a pass two ticks after it: the first timer fires first and is kept,
      # and the later due is recorded.
      :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      stuck = due!(stuck)
      send(scheduler, {:fire, stuck.id})
      {_occurrence_id, released} = left_to_recovery!(scheduler, actor, stuck, slot)

      state = :sys.get_state(scheduler)
      assert state.recovery_ref == first
      assert state.recovery_due >= due_after(released)

      # The first pass runs and re-arms for the recorded due; it found
      # nothing yet, and nothing it ran asked for another.
      send(scheduler, :recover_occurrences)
      rearmed = :sys.get_state(scheduler)
      assert Process.read_timer(first) == false
      assert is_reference(rearmed.recovery_ref) and rearmed.recovery_ref != first
      assert rearmed.recovery_due == state.recovery_due

      left = Process.read_timer(rearmed.recovery_ref)
      assert_in_delta System.monotonic_time(:millisecond) + left, rearmed.recovery_due, 100
      assert ScriptedWorker.calls() == []
    end
  end

  describe "an occurrence the scheduler itself leaves open" do
    test "a claim whose standing runs out before its run starts asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}])
      slot = claimant!(Prima.Boot.id())
      schedule = due!(create_schedule(ctx))

      # The countdown runs out while the claim's INSERT is in its
      # transaction, so the run is deferred right after the claim; then
      # the late renew lands under the same generation.
      handler = lapse_at!("INSERT")
      scheduler = scheduler!()
      assert_receive {:lapsed, claimed}, 10_000
      :telemetry.detach(handler)
      state = :sys.get_state(scheduler)
      renewed!(slot)

      boot = Prima.Boot.id()
      assert [%{state: "claimed", claimed_by: ^boot}] = occurrences(actor, schedule.id)
      assert ScriptedWorker.calls() == []
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(claimed)
    end

    test "a take whose standing runs out before its re-run starts asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}])
      slot = claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = abandoned!(ctx, schedule)

      # The countdown runs out while `recover/4`'s UPDATE takes the claim
      # in the scheduler's first pass, so the re-run is deferred right
      # after the take; then the late renew lands.
      handler = lapse_at!("UPDATE")
      scheduler = scheduler!()
      assert_receive {:lapsed, taken}, 10_000
      :telemetry.detach(handler)
      state = :sys.get_state(scheduler)
      renewed!(slot)

      boot = Prima.Boot.id()

      assert [%{id: ^occurrence_id, state: "claimed", claimed_by: ^boot}] =
               occurrences(actor, schedule.id)

      assert ScriptedWorker.calls() == []
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(taken)
    end

    test "a re-taken occurrence of a paused schedule left unended asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}])
      slot = claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = abandoned!(ctx, schedule)

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
          set: [status: "paused"]
        )

      # The take lands, the schedule will not run, and the standing has
      # run out, so the occurrence is not ended either.
      handler = lapse_at!("UPDATE")
      scheduler = scheduler!()
      assert_receive {:lapsed, taken}, 10_000
      :telemetry.detach(handler)
      state = :sys.get_state(scheduler)
      renewed!(slot)

      boot = Prima.Boot.id()

      assert [%{id: ^occurrence_id, state: "claimed", claimed_by: ^boot}] =
               occurrences(actor, schedule.id)

      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(taken)
    end

    test "a re-taken occurrence whose athanor no longer stands, left unended, asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      script!([%{"ran" => true}])
      slot = claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = abandoned!(ctx, schedule)

      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id),
        set: [status: "archived"]
      )

      handler = lapse_at!("UPDATE")

      log =
        capture_log(fn ->
          scheduler = scheduler!()
          assert_receive {:lapsed, taken}, 10_000
          :telemetry.detach(handler)
          send(self(), {:seen, taken, :sys.get_state(scheduler)})
        end)

      assert_received {:seen, taken, state}
      renewed!(slot)
      assert log =~ "no longer active"

      boot = Prima.Boot.id()

      assert [%{id: ^occurrence_id, state: "claimed", claimed_by: ^boot}] =
               occurrences(actor, schedule.id)

      assert {:ok, %{error_count: 0}} = CronSchedule.get_for_daemon(schedule.id)
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(taken)
    end

    test "a run that exits after this member lost its standing asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      claimant!()
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      _ = :sys.get_state(scheduler)
      [task] = running_tasks()
      ref = Process.monitor(task)

      # The standing runs out while the run waits, and is still lost when
      # the scheduler sees the exit: the not-still-ours branch.
      Arca.ControlPlane.record({:held, 0})
      :ok = :sys.suspend(scheduler)
      released = System.monotonic_time(:millisecond)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 10_000
      refute Arca.ControlPlane.held?()
      :ok = :sys.resume(scheduler)

      state = :sys.get_state(scheduler)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(released)
    end
  end

  describe "a run's end reaches the scheduler" do
    test "a run spawned while the scheduler is held before its monitor waits for it, so no exit goes unseen",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      sup = Process.whereis(Opus.Schedules.TaskSupervisor)
      :ok = :sys.suspend(sup)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()

      # The claim is committed, and the scheduler's request to start the
      # run waits in the task supervisor's mailbox.
      wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)
      wait_until(fn -> spawn_requested?(sup, scheduler) end)

      # The scheduler is held between the start and the monitor, as a busy
      # one is, while the standing has run out: a run that began at once
      # would leave its claim at its own start and be gone unseen.
      :erlang.suspend_process(scheduler)

      try do
        Arca.ControlPlane.record({:held, 0})
        :ok = :sys.resume(sup)
        _ = :sys.get_state(sup)

        wait_until(fn ->
          Enum.all?(running_tasks(), &(not Process.alive?(&1) or waiting_for_monitor?(&1)))
        end)

        renewed!(slot)
      after
        :erlang.resume_process(scheduler)
      end

      # Monitored before it began, the run starts under the standing as it
      # now is and runs its occurrence.
      wait_until(
        fn -> match?([%{state: "completed"}], occurrences(actor, schedule.id)) end,
        10_000
      )

      wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)
      assert [_call] = ScriptedWorker.calls()
    end

    test "a run whose own exit reason never reached the scheduler (:noproc) asks for the two-tick pass",
         %{ctx: ctx} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      scheduler = scheduler!()
      generation = Arca.ControlPlane.generation()
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _reason}
      before = System.monotonic_time(:millisecond)

      # A run this scheduler holds whose monitor found it already gone: its
      # end arrives as `:noproc`, its own reason lost. The start's own pass
      # is set aside, so only what this end asks for is read.
      :sys.replace_state(scheduler, fn state ->
        if state.recovery_ref, do: Process.cancel_timer(state.recovery_ref)

        monitor = Process.monitor(gone)

        task = %{
          ref: monitor,
          schedule_id: schedule.id,
          occurrence_id: "occ_unseen",
          execution_id: "exec_unseen",
          athanor_id: ctx.athanor_id,
          generation: generation,
          ctx: ctx,
          feed?: true
        }

        %{state | tasks: %{monitor => task}, recovery_ref: nil, recovery_due: nil}
      end)

      state = :sys.get_state(scheduler)
      assert state.tasks == %{}
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(before)
    end
  end

  describe "a scheduler started again in the same boot" do
    test "watches the runs its predecessor left in flight, and one left to recovery asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      first = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      _ = :sys.get_state(first)
      [task] = running_tasks()
      ref = Process.monitor(task)

      # The scheduler process dies with the run in flight, and is started
      # again; its start's own pass is set aside, so only what the orphaned
      # run's end asks for is read.
      Process.exit(first, :kill)

      wait_until(fn ->
        pid = Process.whereis(Scheduler)
        is_pid(pid) and pid != first
      end)

      second = Process.whereis(Scheduler)
      no_pass!(second)

      # The run answers after the cached standing ran out, and the late
      # renew lands before the scheduler sees its end.
      Arca.ControlPlane.record({:held, 0})
      released = System.monotonic_time(:millisecond)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, reason}, 10_000
      renewed!(slot)
      state = :sys.get_state(second)
      boot = Prima.Boot.id()

      assert reason == {:shutdown, :left_to_recovery}
      assert [%{state: "started", claimed_by: ^boot}] = occurrences(actor, schedule.id)
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(released)
    end

    test "asks at its start for a pass two ticks away", _context do
      claimant!(Prima.Boot.id())
      started = System.monotonic_time(:millisecond)
      scheduler = scheduler!()
      state = :sys.get_state(scheduler)

      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(started)
    end

    test "reaches a claim committed just before its predecessor died whose run never started",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx))

      # The claim commits for this boot, and the process that made it is
      # gone before it started the run.
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      cadence = %{
        next_after: fn _instant -> {:ok, later} end,
        missed_bound_ms: Opus.Schedules.Scheduler.missed_bound_ms()
      }

      {:ok, %{id: occurrence_id}} = ScheduleOccurrences.claim(schedule, Prima.Boot.id(), cadence)

      started = System.monotonic_time(:millisecond)
      scheduler = scheduler!()
      state = :sys.get_state(scheduler)

      # Its first pass found the claim a live boot's and too young; the pass
      # asked for at its start comes when the claim is two ticks old.
      assert [%{id: ^occurrence_id, state: "claimed"}] = occurrences(actor, schedule.id)
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(started)

      recovered!(scheduler, actor, schedule, occurrence_id)
      assert [_call] = ScriptedWorker.calls()
    end
  end

  describe "an `allow` schedule's overlapping runs" do
    test "a run still in flight when a second of its schedule starts stays held, and its exit left to recovery asks for the two-tick pass",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = ctx |> create_schedule(%{concurrency: "allow"}) |> due!()
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker_a, exec_a}, 10_000
      _ = :sys.get_state(scheduler)
      [task_a] = running_tasks()
      ref_a = Process.monitor(task_a)

      # A person edits the schedule while run A is in flight and its cursor
      # is due: run B of the same schedule claims, runs and ends.
      due!(schedule)
      Scheduler.update(schedule.id)

      wait_until(
        fn ->
          Enum.count(occurrences(actor, schedule.id), &(&1.state == "completed")) == 1 and
            Enum.all?(Map.values(:sys.get_state(scheduler).tasks), &(&1.execution_id == exec_a))
        end,
        10_000
      )

      # Run A is still in flight, and still held: B did not displace it.
      assert Process.alive?(task_a)
      assert [%{execution_id: ^exec_a}] = Map.values(:sys.get_state(scheduler).tasks)
      no_pass!(scheduler)

      # A answers after the cached standing ran out, and the late renew
      # lands before the scheduler sees its end.
      Arca.ControlPlane.record({:held, 0})
      :ok = :sys.suspend(scheduler)
      released = System.monotonic_time(:millisecond)
      send(worker_a, :continue)
      assert_receive {:DOWN, ^ref_a, :process, ^task_a, reason}, 10_000
      renewed!(slot)
      :ok = :sys.resume(scheduler)
      state = :sys.get_state(scheduler)
      boot = Prima.Boot.id()

      assert reason == {:shutdown, :left_to_recovery}

      assert [%{state: "started", claimed_by: ^boot}] =
               Enum.filter(occurrences(actor, schedule.id), &(&1.execution_id == exec_a))

      assert state.tasks == %{}
      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(released)
    end

    test "a run this process does not hold, ending left to recovery, asks for the two-tick pass",
         _context do
      claimant!(Prima.Boot.id())
      scheduler = scheduler!()
      no_pass!(scheduler)
      before = System.monotonic_time(:millisecond)

      # The end of a run the scheduler holds no record of, its reason the
      # run's own word that it left its occurrence to recovery.
      send(scheduler, {:DOWN, make_ref(), :process, self(), {:shutdown, :left_to_recovery}})
      state = :sys.get_state(scheduler)

      assert is_reference(state.recovery_ref)
      assert state.recovery_due >= due_after(before)
    end

    test "a pass re-runs a left occurrence while another run of its schedule is in flight",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      # Run B's answer after its probe, and X's re-run's.
      script!([{:probe, self()}, %{"ran" => true}, %{"ran" => true}])
      schedule = ctx |> create_schedule(%{concurrency: "allow"}) |> due!()
      :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()

      # Occurrence X is left claimed by this live boot: its admission was
      # refused for the slot, with no successor.
      {x_id, _released} = left_to_recovery!(scheduler, actor, schedule, slot)

      # The schedule's next fire claims another occurrence, whose run waits
      # in flight.
      due!(schedule)
      send(scheduler, {:fire, schedule.id})
      assert_receive {:scripted_probe, worker_b, _exec_b}, 10_000
      _ = :sys.get_state(scheduler)
      assert map_size(:sys.get_state(scheduler).tasks) == 1

      # X's claim is two ticks old when its pass comes.
      age!(x_id)
      send(scheduler, :recover_occurrences)

      wait_until(
        fn ->
          match?(
            %{state: "completed"},
            Enum.find(occurrences(actor, schedule.id), &(&1.id == x_id))
          )
        end,
        10_000
      )

      send(worker_b, :continue)
      wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end, 10_000)
      assert Enum.all?(occurrences(actor, schedule.id), &(&1.state == "completed"))
    end
  end

  describe "the standing pass" do
    test "reaches an occurrence left to recovery when no exit asked for a pass at all",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()
      {occurrence_id, _released} = left_to_recovery!(scheduler, actor, schedule, slot)

      # The fast path is set aside: no pass any exit or start asked for is
      # left, so only the standing pass can reach the occurrence.
      no_pass!(scheduler)
      age!(occurrence_id)
      fired_at = System.monotonic_time(:millisecond)
      first = standing_fires!(scheduler)
      returned_at = System.monotonic_time(:millisecond)

      # It comes again two ticks and a second after it fired, asked by
      # nothing: the pass re-armed its timer between the two instants, so
      # the timer is due that period after one of them. Its remaining time
      # is read between two clock reads and each bound is held with the
      # read on its own side, so a stall between the reads widens the
      # bracket and never narrows it (a millisecond is allowed for the
      # timer's rounding).
      state = :sys.get_state(scheduler)
      assert state.standing_ref != first
      before = System.monotonic_time(:millisecond)
      left = Process.read_timer(state.standing_ref)
      after_read = System.monotonic_time(:millisecond)
      period = 2 * @tick_ms + Arca.ControlPlane.margin_ms()
      assert after_read + left >= fired_at + period - 1
      assert before + left <= returned_at + period

      wait_until(
        fn ->
          match?([%{id: ^occurrence_id, state: "completed"}], occurrences(actor, schedule.id))
        end,
        10_000
      )

      assert [_call] = ScriptedWorker.calls()
    end

    test "leaves a run in flight to end its own occurrence, though its execution has just closed",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler = scheduler!()
      {task, occurrence_id, execution_id} = closing_run!(scheduler, actor, schedule)

      # The standing pass comes between the run's close and its task's own
      # end of the occurrence, the run having gone on past two ticks.
      try do
        standing_fires!(scheduler)
        assert [%{id: ^occurrence_id, state: "started"}] = occurrences(actor, schedule.id)
      after
        :erlang.resume_process(task)
      end

      ended_by_its_run!(scheduler, actor, schedule, occurrence_id, execution_id)
    end

    test "leaves a run in flight to end its own occurrence, though it has been seen lapsed for two ticks",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler = scheduler!()
      {task, occurrence_id, execution_id} = closing_run!(scheduler, actor, schedule)

      # A pass sees the occurrence lapsed, and two ticks pass on its clock:
      # the grace is spent, and only the run still held in flight keeps it.
      try do
        standing_fires!(scheduler)
        assert Map.has_key?(seen(scheduler), occurrence_id)
        seen_long_ago!(scheduler)
        standing_fires!(scheduler)
        assert [%{id: ^occurrence_id, state: "started"}] = occurrences(actor, schedule.id)
      after
        :erlang.resume_process(task)
      end

      ended_by_its_run!(scheduler, actor, schedule, occurrence_id, execution_id)
    end

    test "lets a run its restarted scheduler adopted end its own occurrence, though its member's clock lags the cell's",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      first = scheduler!()
      assert_receive {:scripted_probe, worker, execution_id}, 10_000
      _ = :sys.get_state(first)
      [task] = running_tasks()

      assert [%{id: occurrence_id, state: "started", execution_id: ^execution_id}] =
               occurrences(actor, schedule.id)

      # The scheduler process dies with the run in flight and starts again
      # in this boot, which adopts the run but holds none of its own.
      Process.exit(first, :kill)

      wait_until(fn ->
        pid = Process.whereis(Scheduler)
        is_pid(pid) and pid != first
      end)

      second = Process.whereis(Scheduler)
      _ = :sys.get_state(second)
      no_pass!(second)

      refute Enum.any?(
               Map.values(:sys.get_state(second).tasks),
               &(&1.occurrence_id == occurrence_id)
             )

      # The run has gone on past two ticks; it closes its execution, stamped
      # by a member whose wall clock runs a minute behind the cell's, and its
      # task is held before its own end of the occurrence.
      age!(occurrence_id)
      :erlang.suspend_process(task)
      ref = Process.monitor(task)

      try do
        send(worker, :continue)

        wait_until(
          fn ->
            Arca.Repo.one(
              from(e in Arca.Schemas.Execution, where: e.id == ^execution_id, select: e.status)
            ) == "completed"
          end,
          10_000
        )

        lagging = DateTime.add(DateTime.utc_now(), -61, :second)

        {1, _} =
          Arca.Repo.update_all(
            from(e in Arca.Schemas.Execution, where: e.id == ^execution_id),
            set: [completed_at: lagging]
          )

        standing_fires!(second)
        assert [%{id: ^occurrence_id, state: "started"}] = occurrences(actor, schedule.id)
      after
        :erlang.resume_process(task)
      end

      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 10_000
      _ = :sys.get_state(second)
      {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
      assert [%{id: ^occurrence_id, state: "completed"}] = occurrences(actor, schedule.id)
      assert row.run_count == 1
      assert row.last_execution_id == execution_id
    end

    test "ends a live member's lapsed occurrence its member's clock stamped an hour ahead, two ticks after first seeing it",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      lapsed_live!(ctx, schedule, DateTime.add(DateTime.utc_now(), 3_600, :second))

      # The start's own pass sees it lapsed, and does not end it yet.
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)

      # Two ticks later on the scheduler's own clock, the next pass ends it,
      # whatever the execution's end time says.
      seen_long_ago!(scheduler)
      standing_fires!(scheduler)
      assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    end

    test "gives a live member's occurrence whose execution row is gone the same two ticks",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = lapsed_live!(ctx, schedule, nil)

      # The start's own pass has run before anything is read.
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)
      assert Map.has_key?(seen(scheduler), occurrence_id)

      seen_long_ago!(scheduler)
      standing_fires!(scheduler)
      assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    end

    test "leaves a live member's lapsed occurrence it has seen so for one tick, and ends it at two",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      lapsed_live!(ctx, schedule, DateTime.utc_now())
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)

      # Seen lapsed one tick ago: the grace is two, so it is left.
      seen_ago!(scheduler, @tick_ms)
      standing_fires!(scheduler)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)

      # Seen two ticks and a second ago: ended.
      seen_ago!(scheduler, 2 * @tick_ms + 1_000)
      standing_fires!(scheduler)
      assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    end

    test "stamps a lapsed occurrence first seen no earlier than the read that saw it",
         %{ctx: ctx} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      {occurrence_id, execution_id} = running_live!(ctx, schedule)
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)
      assert seen(scheduler) == %{}

      # The next pass is held at its first read, as a slow database holds
      # it, and the run's execution closes meanwhile.
      once = hold_first_read!()
      %{standing_ref: pending} = :sys.get_state(scheduler)
      Process.cancel_timer(pending)
      send(scheduler, :standing_pass)
      assert_receive {^once, :held, held, held_at}, 10_000

      # The close is a clock tick later than the hold, so a sighting stamped
      # before the read could not equal it.
      wait_until(fn -> System.monotonic_time(:millisecond) > held_at end)

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^execution_id),
          set: [status: "completed", completed_at: DateTime.utc_now()]
        )

      closed = System.monotonic_time(:millisecond)
      send(held, {once, :release})

      # The pass saw it lapsed only after the close: its grace starts there.
      assert Map.fetch!(seen(scheduler), occurrence_id) >= closed
    end

    test "after a slow first sighting, the next standing pass ends the occurrence, two ticks and at most a second later",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      {occurrence_id, execution_id} = running_live!(ctx, schedule)
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)
      no_pass!(scheduler)

      # Its run is gone and its execution closed: nobody will end it but a
      # recovery pass.
      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^execution_id),
          set: [status: "completed", completed_at: DateTime.utc_now()]
        )

      # A standing pass whose first read is slow, 300 ms, first sees it lapsed.
      once = hold_first_read!()
      %{standing_ref: pending} = :sys.get_state(scheduler)
      Process.cancel_timer(pending)
      send(scheduler, :standing_pass)
      assert_receive {^once, :held, held, held_at}, 10_000
      wait_until(fn -> System.monotonic_time(:millisecond) >= held_at + 300 end)
      send(held, {once, :release})
      state = :sys.get_state(scheduler)
      first = Map.fetch!(state.lapsed_seen, occurrence_id)
      now = System.monotonic_time(:millisecond)
      next = now + Process.read_timer(state.standing_ref)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)

      # The next standing pass, the one its own timer fires, is due at least
      # the grace after the sighting and at most the grace and a second.
      assert next - first >= 2 * @tick_ms
      assert next - first <= 2 * @tick_ms + Arca.ControlPlane.margin_ms()

      # That pass, delivered as its timer would deliver it, ends the
      # occurrence: the sighting is set back by the time still to wait.
      :sys.replace_state(scheduler, fn state ->
        left = next - System.monotonic_time(:millisecond)
        %{state | lapsed_seen: Map.update!(state.lapsed_seen, occurrence_id, &(&1 - left))}
      end)

      standing_fires!(scheduler)
      assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    end

    test "graces a live member's lapsed occurrence until two ticks of its own clock have passed",
         %{ctx: ctx, actor: actor} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = lapsed_live!(ctx, schedule, DateTime.utc_now())
      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)

      # First seen: recorded, not ended.
      assert Map.has_key?(seen(scheduler), occurrence_id)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)

      # A second short of two ticks: still graced, and its sighting kept.
      seen_ago!(scheduler, 2 * @tick_ms - 1_000)
      standing_fires!(scheduler)
      assert [%{state: "started"}] = occurrences(actor, schedule.id)
      assert Map.has_key?(seen(scheduler), occurrence_id)

      # Two ticks, read on the pass's own clock at or after them: ended.
      seen_ago!(scheduler, 2 * @tick_ms)
      standing_fires!(scheduler)
      assert [%{state: "uncertain"}] = occurrences(actor, schedule.id)
    end

    test "forgets an occurrence it saw lapsed once it is no longer lapsed", %{ctx: ctx} do
      claimant!(Prima.Boot.id())
      schedule = create_schedule(ctx)
      occurrence_id = lapsed_live!(ctx, schedule, DateTime.utc_now())
      scheduler = scheduler!()
      assert Map.has_key?(seen(scheduler), occurrence_id)

      # Its own run's task ends it, as a run does.
      [%{execution_id: execution_id}] = occurrences(Sanctum.Context.actor(ctx), schedule.id)

      assert {:ok, 1} =
               ScheduleOccurrences.finish(
                 Sanctum.Context.actor(ctx),
                 occurrence_id,
                 Prima.Boot.id(),
                 execution_id,
                 "completed"
               )

      standing_fires!(scheduler)
      assert seen(scheduler) == %{}
    end

    test "runs nothing while this member does not hold its slot, and reaches the occurrence once it does",
         %{ctx: ctx, actor: actor} do
      slot = claimant!(Prima.Boot.id())
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()
      {occurrence_id, _released} = left_to_recovery!(scheduler, actor, schedule, slot)
      no_pass!(scheduler)
      age!(occurrence_id)
      reads = watch_recovery_reads()

      # The standing is lost: the pass reads nothing and re-runs nothing,
      # and comes again two ticks later.
      Arca.ControlPlane.record(:lost)
      first = standing_fires!(scheduler)
      state = :sys.get_state(scheduler)
      refute_received {^reads, :read}
      assert [%{id: ^occurrence_id, state: "claimed"}] = occurrences(actor, schedule.id)
      assert state.standing_ref != first
      assert is_integer(Process.read_timer(state.standing_ref))

      # Held again, the next standing pass reaches it.
      renewed!(slot)
      standing_fires!(scheduler)
      assert_received {^reads, :read}

      wait_until(
        fn ->
          match?([%{id: ^occurrence_id, state: "completed"}], occurrences(actor, schedule.id))
        end,
        10_000
      )
    end
  end

  # ---- helpers -------------------------------------------------------------------

  # The scheduled component, registered, and the profile schedules name
  # with its head consent: the component's node under the fixture limits.
  # The grant admits the runs a schedule starts and the person's own.
  defp consented!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: "test",
        version: "1.0.0",
        type: "reagent"
      })

    profile = %{
      id: @profile_id,
      kind: :owner,
      source_ref: @reference,
      label: "default",
      status: :active
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-#{@profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{@profile_id}",
        commit_digest: "sha256:commit-#{@profile_id}",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @reference => %{
                "limits" => AuthorityFixtures.limits_map(),
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@reference => component.release_digest},
        admitted_origins: [:interactive, :schedule],
        vault_refs: []
      })
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  # The scheduler under test, started after the rows it should find.
  defp scheduler!, do: start_supervised!(Scheduler)

  defp create_schedule(ctx, attrs \\ %{}) do
    {:ok, schedule} =
      %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "fence-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: @profile_id,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cap: 1_000
      }
      |> Map.merge(attrs)
      |> then(&CronSchedule.create(Sanctum.Context.actor(ctx), &1))

    schedule
  end

  # Due a few seconds ago: an ordinary occurrence, within the missed bound.
  defp due!(schedule) do
    past = DateTime.add(DateTime.utc_now(), -5, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp occurrences(actor, schedule_id) do
    {:ok, rows} = ScheduleOccurrences.list(actor, schedule_id)
    rows
  end

  defp fire_decisions do
    Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == "schedule"))
  end

  defp running_tasks do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Opus.Schedules.TaskSupervisor),
        is_pid(pid),
        do: pid
  end

  # The outcomes the scheduler emits.
  defp watch_outcomes do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:cyfr, :schedules, :completed], [:cyfr, :schedules, :failed]],
      fn event, _measurements, _metadata, test -> send(test, {:schedule_outcome, event}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none, which would leave a
  # write's live check nothing to check.
  #
  # `owner` is the boot the slot is held for: a stand-in's by default, or
  # this boot's own, which makes the occurrences it claims a live member's.
  defp claimant!(owner \\ nil) do
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
    node = "node-fence-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, owner || node <> "#boot_a", 60_000)
    slot
  end

  # The due a pass asked for when an occurrence was left at `instant`
  # must be at least: two ticks and the control plane's margin after it.
  defp due_after(instant), do: instant + 2 * @tick_ms + Arca.ControlPlane.margin_ms()

  # The schedule's fire was answered and deferred: its timer is the
  # recheck, a tick or more away, and no longer the fire it was loaded
  # with, which is due at once.
  defp deferred?(scheduler, schedule_id) do
    timer = :sys.get_state(scheduler).timers[schedule_id]
    is_reference(timer) and (Process.read_timer(timer) || 0) > div(@tick_ms, 2)
  end

  # A recovery pass is armed to fire within `ms`.
  defp pass_within?(scheduler, ms) do
    case :sys.get_state(scheduler).recovery_ref do
      ref when is_reference(ref) ->
        left = Process.read_timer(ref)
        is_integer(left) and left <= ms

      nil ->
        false
    end
  end

  # The scheduler asked the task supervisor to start a run, and waits for
  # its answer.
  defp spawn_requested?(sup, scheduler) do
    {:messages, messages} = Process.info(sup, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^scheduler, _tag}, _request}, &1))
  end

  # A run started by `Task.Supervisor.async_nolink/3` waits in
  # `Task.Supervised`'s handshake until its caller has monitored it.
  defp waiting_for_monitor?(task),
    do:
      match?(
        {:current_function, {Task.Supervised, :reply, 4}},
        Process.info(task, :current_function)
      )

  # A run that has gone on past two ticks closes its execution, and its
  # task is held between that close and its own end of the occurrence, as
  # a loaded host deschedules it; every pass anything asked for is set
  # aside. Answers the held task, the occurrence and the execution.
  defp closing_run!(scheduler, actor, schedule) do
    assert_receive {:scripted_probe, worker, execution_id}, 10_000
    _ = :sys.get_state(scheduler)
    [task] = running_tasks()

    assert [%{id: occurrence_id, state: "started", execution_id: ^execution_id}] =
             occurrences(actor, schedule.id)

    no_pass!(scheduler)
    age!(occurrence_id)
    :erlang.suspend_process(task)
    send(worker, :continue)

    # Its own wait failing resumes the task it suspended before re-raising.
    # An exit instead ends the test process, and the runtime lifts every
    # suspension a process made when it exits; only the suspending process
    # may resume, so an `on_exit` callback, run in another, could not.
    try do
      wait_until(
        fn ->
          Arca.Repo.one(
            from(e in Arca.Schemas.Execution, where: e.id == ^execution_id, select: e.status)
          ) == "completed"
        end,
        10_000
      )

      assert Process.alive?(task)

      assert Enum.any?(
               Map.values(:sys.get_state(scheduler).tasks),
               &(&1.execution_id == execution_id)
             )
    rescue
      error ->
        :erlang.resume_process(task)
        reraise error, __STACKTRACE__
    end

    {task, occurrence_id, execution_id}
  end

  # Every occurrence the scheduler has seen lapsed was first seen two ticks
  # and a second ago on its own clock, as if that much time had passed.
  defp seen_long_ago!(scheduler) do
    :sys.replace_state(scheduler, fn state ->
      Map.update(state, :lapsed_seen, %{}, fn seen ->
        Map.new(seen, fn {id, at} -> {id, at - 2 * @tick_ms - 1_000} end)
      end)
    end)
  end

  # Every occurrence the scheduler has seen lapsed was first seen `ms` ago
  # on its own clock.
  defp seen_ago!(scheduler, ms) do
    :sys.replace_state(scheduler, fn state ->
      Map.update(state, :lapsed_seen, %{}, fn seen ->
        at = System.monotonic_time(:millisecond) - ms
        Map.new(seen, fn {id, _first} -> {id, at} end)
      end)
    end)
  end

  # The scheduler's next first read of `schedule_occurrences` is held until
  # the test releases it, as a slow database holds a pass. The hold tells the
  # test its process and the instant it began. Answers the tag the hold's
  # messages carry.
  defp hold_first_read! do
    test = self()
    once = make_ref()
    taken = :atomics.new(1, [])
    handler = "fence-hold-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if Process.whereis(Scheduler) == self() and meta[:source] == "schedule_occurrences" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], "SELECT") and
             :atomics.compare_exchange(taken, 1, 0, 1) == :ok do
          send(test, {once, :held, self(), System.monotonic_time(:millisecond)})

          receive do
            {^once, :release} -> :ok
          after
            10_000 -> :ok
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    once
  end

  # A live member's started occurrence whose run's execution is still
  # running, its claim two ticks old. Answers it and its execution.
  defp running_live!(ctx, schedule) do
    root = Prima.UUID7.execution_id()

    execution =
      Arca.Repo.insert!(%Arca.Schemas.Execution{
        id: root,
        root_execution_id: root,
        reference: "reagent:local.test:1.0.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        started_at: DateTime.utc_now(),
        status: "running"
      })

    occurrence =
      Arca.Repo.insert!(%ScheduleOccurrence{
        id: Prima.UUID7.generate_id("occ"),
        athanor_id: ctx.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(DateTime.utc_now(), -3_600, :second),
        state: "started",
        execution_id: execution.id,
        attempts: 1,
        claimed_by: Prima.Boot.id(),
        claimed_at:
          DateTime.add(Arca.ServerMetaStorage.now!(), -2 * @tick_ms - 1_000, :millisecond)
      })

    {occurrence.id, execution.id}
  end

  # What the scheduler has seen lapsed, by occurrence id.
  defp seen(scheduler), do: Map.get(:sys.get_state(scheduler), :lapsed_seen, %{})

  # A live member's started occurrence whose run is gone and whose execution
  # ended as `execution` says (nil: its row is gone), its claim two ticks old.
  defp lapsed_live!(ctx, schedule, execution) do
    execution_id =
      case execution do
        nil ->
          "exec_gone_#{System.unique_integer([:positive])}"

        completed_at ->
          root = Prima.UUID7.execution_id()

          Arca.Repo.insert!(%Arca.Schemas.Execution{
            id: root,
            root_execution_id: root,
            reference: "reagent:local.test:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            started_at: DateTime.utc_now(),
            status: "completed",
            completed_at: completed_at
          }).id
      end

    occurrence =
      Arca.Repo.insert!(%ScheduleOccurrence{
        id: Prima.UUID7.generate_id("occ"),
        athanor_id: ctx.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(DateTime.utc_now(), -3_600, :second),
        state: "started",
        execution_id: execution_id,
        attempts: 1,
        claimed_by: Prima.Boot.id(),
        claimed_at:
          DateTime.add(Arca.ServerMetaStorage.now!(), -2 * @tick_ms - 1_000, :millisecond)
      })

    occurrence.id
  end

  # The run's own task ended its occurrence completed and recorded the run.
  defp ended_by_its_run!(scheduler, actor, schedule, occurrence_id, execution_id) do
    wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end, 10_000)
    {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
    assert [%{id: ^occurrence_id, state: "completed"}] = occurrences(actor, schedule.id)
    assert row.run_count == 1
    assert row.last_execution_id == execution_id
  end

  # The standing pass's timer fires: the pending one is taken off and its
  # message delivered, as its expiry would. Answers the timer it replaced.
  defp standing_fires!(scheduler) do
    %{standing_ref: pending} = :sys.get_state(scheduler)
    Process.cancel_timer(pending)
    send(scheduler, :standing_pass)
    _ = :sys.get_state(scheduler)
    pending
  end

  # The occurrence's claim is two ticks old, as a pass at its due finds it.
  defp age!(occurrence_id) do
    aged = DateTime.add(Arca.ServerMetaStorage.now!(), -2 * @tick_ms - 1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(o in ScheduleOccurrence, where: o.id == ^occurrence_id),
        set: [claimed_at: aged]
      )

    :ok
  end

  # Each recovery read the scheduler makes is told to the test, tagged with
  # the answered reference.
  defp watch_recovery_reads do
    test = self()
    tag = make_ref()
    handler = "fence-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if Process.whereis(Scheduler) == self() and meta[:source] == "schedule_occurrences" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], "SELECT") do
          send(test, {tag, :read})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    tag
  end

  # No pass asked for so far is left: the case reads only what its own
  # path asks for.
  defp no_pass!(scheduler) do
    :sys.replace_state(scheduler, fn state ->
      if state.recovery_ref, do: Process.cancel_timer(state.recovery_ref)
      %{state | recovery_ref: nil, recovery_due: nil}
    end)
  end

  # The cached countdown runs out, as a late renew lets it, at the
  # scheduler's own first statement on `schedule_occurrences` that starts
  # with `verb`, in that statement's transaction; the test is told when.
  defp lapse_at!(verb) do
    test = self()
    handler = "fence-lapse-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if Process.whereis(Scheduler) == self() and meta[:source] == "schedule_occurrences" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], verb) and
             Arca.ControlPlane.held?() do
          Arca.ControlPlane.record({:held, 0})
          send(test, {:lapsed, System.monotonic_time(:millisecond)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  # The late renew lands: the standing is back under the same generation.
  defp renewed!(slot) do
    Arca.ControlPlane.record({:held, 60_000})
    assert {:ok, slot.generation} == Arca.ControlPlane.generation()
    assert Arca.ControlPlane.held?()
  end

  # An occurrence a member that is gone claimed and never invoked: the
  # scheduler's first recovery pass takes it.
  defp abandoned!(ctx, schedule) do
    occurrence =
      Arca.Repo.insert!(%ScheduleOccurrence{
        id: Prima.UUID7.generate_id("occ"),
        athanor_id: ctx.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second),
        state: "claimed",
        claimed_by: "gone",
        claimed_at: Arca.ServerMetaStorage.now!()
      })

    occurrence.id
  end

  # This member's lease runs out on the cell's clock with no successor: the
  # row still names it, so its own renew takes the slot back.
  defp lapse!(%{node: node}) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [lease_until: past]
      )

    :ok
  end

  # A live member leaves its claimed occurrence to recovery. The claim is
  # made while the slot holds, and the run is held before its admission
  # (the task supervisor is suspended by the caller); the lease lapses with
  # no successor, so the admission's own check refuses the run, and the
  # member renews once the run has exited. Answers the occurrence's id and
  # the monotonic instant the run was let go, after its claim.
  defp left_to_recovery!(scheduler, actor, schedule, slot) do
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)
    [%{id: occurrence_id}] = occurrences(actor, schedule.id)
    lapse!(slot)
    released = System.monotonic_time(:millisecond)
    :ok = :sys.resume(Opus.Schedules.TaskSupervisor)
    wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)
    assert {:ok, _} = Arca.ControlPlane.renew(60_000)

    # Left claimed by this live boot, never invoked.
    boot = Prima.Boot.id()
    assert [%{state: "claimed", claimed_by: ^boot}] = occurrences(actor, schedule.id)
    {occurrence_id, released}
  end

  # A `forbid` schedule whose run a live member left to recovery, fired
  # again inside the window, so it answers `:overlapping`. Answers the
  # scheduler, the schedule, the occurrence's id, the instant the run was
  # let go and the scheduler's state after the overlap.
  defp stuck!(ctx, actor) do
    slot = claimant!(Prima.Boot.id())
    schedule = due!(create_schedule(ctx))
    :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    {occurrence_id, released} = left_to_recovery!(scheduler, actor, schedule, slot)

    schedule = due!(schedule)
    send(scheduler, {:fire, schedule.id})
    state = :sys.get_state(scheduler)
    assert [%{id: ^occurrence_id, state: "claimed"}] = occurrences(actor, schedule.id)
    {scheduler, schedule, occurrence_id, released, state}
  end

  # The claim aged two ticks, as a pass at its due finds it, and the pass
  # delivered: the occurrence is recovered and runs.
  defp recovered!(scheduler, actor, schedule, occurrence_id) do
    aged = DateTime.add(Arca.ServerMetaStorage.now!(), -2 * @tick_ms - 1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(o in ScheduleOccurrence, where: o.id == ^occurrence_id),
        set: [claimed_at: aged]
      )

    send(scheduler, :recover_occurrences)

    wait_until(
      fn ->
        Enum.any?(
          occurrences(actor, schedule.id),
          &match?(%{id: ^occurrence_id, state: "completed"}, &1)
        )
      end,
      10_000
    )
  end

  # The recovered occurrence and the schedule's next one, which the due
  # cursor fires as soon as the recovered run ends, have both run, and no
  # run is in flight.
  defp settled!(scheduler, actor, schedule) do
    wait_until(
      fn ->
        match?([%{state: "completed"}, %{state: "completed"}], occurrences(actor, schedule.id)) and
          :sys.get_state(scheduler).tasks == %{}
      end,
      10_000
    )
  end

  # A successor takes the slot over after this member read it: this member
  # still believes it holds it, so only a write's own live check stands
  # between it and the row.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end
end

defmodule Opus.Schedules.OwnershipFenceFeedsTest do
  @moduledoc """
  A feed's run that leaves its claimed occurrence to recovery: its seq
  claim or its result refused `:not_owner` after a successor took the
  slot over. The task ends `{:shutdown, :left_to_recovery}`, so the
  scheduler, still believing it holds its slot, asks for the pass due two
  ticks after the exit. The fires run through the real scheduler path with
  the markets catalyst's feed fixtures and the scripted worker service.
  """

  # Starts the scheduler, takes a slot through `Arca.ControlPlane` and
  # switches the claimant on; each case restores what it changed.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Opus.Schedules.Scheduler
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "catalyst:local.markets"
  @pinned "catalyst:local.markets:1.0.0"
  @profile_id "prof_feeds"

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  # The scheduler's recheck tick.
  @tick_ms 30_000

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "fence_feeds_#{System.unique_integer([:positive])}")
    keys = [cyfr: :cron_scheduler_enabled, cyfr: :locus_runtime_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)

    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers(@reference, prev[{:cyfr, :locus_runtime_workers}])
    )

    Application.put_env(:arca, :base_path, test_path)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    consented!(ctx)
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  test "a run whose seq claim is refused :not_owner asks for the two-tick pass", %{
    actor: actor
  } do
    slot = claimant!()
    script!([%{"price" => 1.0}])
    {:ok, feed} = bind(actor, feed_binding("btc"))

    # The claim is made while the slot is this member's; the run is held
    # before its seq claim while a successor takes the slot over.
    :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, feed.id)) end)
    take_over!(slot)
    assert Arca.ControlPlane.held?()
    released = System.monotonic_time(:millisecond)
    :ok = :sys.resume(Opus.Schedules.TaskSupervisor)
    wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)

    state = :sys.get_state(scheduler)
    assert [%{state: "claimed"}] = occurrences(actor, feed.id)
    assert {:ok, %{feed_fire_seq: 0}} = CronSchedule.get_for_daemon(feed.id)
    assert is_reference(state.recovery_ref)
    assert state.recovery_due >= due_after(released)
  end

  test "a run whose result is refused :not_owner asks for the two-tick pass", %{actor: actor} do
    slot = claimant!()
    script!([{:probe, self()}, %{"price" => 1.0}])
    {:ok, feed} = bind(actor, feed_binding("btc"))
    scheduler = scheduler!()
    assert_receive {:scripted_probe, worker, _execution_id}, 10_000
    _ = :sys.get_state(scheduler)
    [task] = running_tasks()
    ref = Process.monitor(task)

    # A successor takes the slot over while the run is in flight; this
    # member still believes it holds it, so only the acceptance's own
    # check refuses the result.
    take_over!(slot)
    released = System.monotonic_time(:millisecond)
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 10_000

    state = :sys.get_state(scheduler)
    assert [%{state: "started"}] = occurrences(actor, feed.id)
    assert {:ok, %{feed_result_seq: 0}} = CronSchedule.get_for_daemon(feed.id)
    assert is_reference(state.recovery_ref)
    assert state.recovery_due >= due_after(released)
  end

  # ---- helpers -------------------------------------------------------------------

  defp due_after(instant), do: instant + 2 * @tick_ms + Arca.ControlPlane.margin_ms()

  # The feed fixtures: the markets catalyst registered, and the profile
  # feeds name with its head consent, admitting scheduled runs.
  defp consented!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: "markets",
        version: "1.0.0",
        type: "catalyst"
      })

    profile = %{
      id: @profile_id,
      kind: :owner,
      source_ref: @reference,
      label: "default",
      status: :active
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-#{@profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{@profile_id}",
        commit_digest: "sha256:commit-#{@profile_id}",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @reference => %{
                "limits" => AuthorityFixtures.limits_map(),
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@reference => component.release_digest},
        admitted_origins: [:interactive, :schedule],
        vault_refs: []
      })
  end

  defp feed_binding(name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => @reference,
        "operation" => "quote",
        "args" => %{"symbol" => String.upcase(name)},
        "interval_minutes" => 5,
        "result_shape" => %{
          "type" => "object",
          "fields" => %{"price" => %{"type" => "number"}},
          "required" => ["price"]
        },
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    binding
  end

  defp bind(actor, binding) do
    CronSchedule.create_feed(actor, %{
      binding: binding,
      resolved_reference: @pinned,
      profile_id: @profile_id,
      cap: 1_000
    })
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  defp scheduler!, do: start_supervised!(Scheduler)

  defp occurrences(actor, schedule_id) do
    {:ok, rows} = ScheduleOccurrences.list(actor, schedule_id)
    rows
  end

  defp running_tasks do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Opus.Schedules.TaskSupervisor),
        is_pid(pid),
        do: pid
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot; the standing record and the switch are restored when the case
  # ends.
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
    node = "node-fence-feeds-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over after this member read it: this member
  # still believes it holds it.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end
end
