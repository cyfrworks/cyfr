# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Schedules.OwnershipFenceTest do
  @moduledoc """
  What the scheduler does when a write's own check finds the occurrence is
  no longer this member's, while its cached standing still says it is.

  A claim or an admission refused `:not_owner` was refused by the
  database, in the write's own transaction: the occurrence is left to
  recovery, with nothing written and no error recorded. A finish or a
  dead runner's settlement answered `:stale` found the occurrence another
  member's now: the decision this member opened is closed with the run's
  answer, and nothing else is written.

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
  alias Crucible.Schedules.Scheduler
  alias Cyfr.Bus.ScheduleCompleted
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.test"
  @profile_id "prof_test"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "fence_#{System.unique_integer([:positive])}")
    keys = [cyfr: :cron_scheduler_enabled, cyfr: :opus_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)

    Application.put_env(
      :cyfr,
      :opus_workers,
      ScriptedWorker.workers(@reference, prev[{:cyfr, :opus_workers}])
    )

    Application.put_env(:arca, :base_path, test_path)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    consented!(ctx)
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
    # defers: the schedule is looked at again later and recovery is armed.
    wait_until(fn -> is_reference(:sys.get_state(scheduler).recovery_ref) end)
    state = :sys.get_state(scheduler)
    assert is_integer(Process.read_timer(state.timers[schedule.id]))

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
    :ok = :sys.suspend(Crucible.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Crucible.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)

    take_over!(slot)
    assert Arca.ControlPlane.held?()

    log =
      capture_log(fn ->
        :ok = :sys.resume(Crucible.Schedules.TaskSupervisor)
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
    :ok = :sys.suspend(Crucible.Schedules.TaskSupervisor)
    on_exit(fn -> :sys.resume(Crucible.Schedules.TaskSupervisor) end)
    scheduler = scheduler!()
    wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, schedule.id)) end)
    [%{id: occurrence_id}] = occurrences(actor, schedule.id)

    assert :ok =
             ScheduleOccurrences.recover(actor, occurrence_id, Prima.Boot.id(), "boot-successor")

    assert 1 = ScheduleOccurrences.start!(actor, occurrence_id, "exec_successor")

    log =
      capture_log(fn ->
        :ok = :sys.resume(Crucible.Schedules.TaskSupervisor)
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

  # ---- helpers -------------------------------------------------------------------

  # The scheduled component, registered, and the profile schedules name
  # with its head consent: the component's node under the fixture limits.
  # The grant admits the runs a schedule starts and the person's own.
  defp consented!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
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

  defp create_schedule(ctx) do
    {:ok, schedule} =
      CronSchedule.create(%{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "fence-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: @profile_id,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    schedule
  end

  defp due!(schedule) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

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
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Crucible.Schedules.TaskSupervisor),
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
    node = "node-fence-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
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
