# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Schedules.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Schedules.Scheduler
  alias Cyfr.Test.{AuthorityFixtures, ScriptedWorker}
  alias Sanctum.Consent.Source

  @reference "reagent:local.test"
  @profile_id "prof_test"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "scheduler_#{System.unique_integer([:positive])}")
    keys = [:cron_scheduler_enabled, :workers, :base_path]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)
    Application.put_env(:cyfr, :workers, [ScriptedWorker])
    Application.put_env(:cyfr, :base_path, test_path)
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    Sanctum.Test.ConsentFixtures.start_source!()
    consented!(ctx)
    {:ok, ctx: ctx}
  end

  # The scheduled component, registered, and the profile schedules name
  # with its head consent: the component's node under the fixture limits.
  defp consented!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "test",
        version: "1.0.0",
        type: "reagent"
      })

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: @profile_id,
        kind: :owner,
        source_ref: @reference,
        label: "default",
        status: :active
      })

    :ok =
      Source.Memory.put_head_consent(ctx, @profile_id, %{
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
        vault_refs: []
      })
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  # The scheduler under test, started after the rows it should find.
  defp scheduler!, do: start_supervised!(Scheduler)

  defp create_schedule(ctx, attrs \\ %{}) do
    {:ok, schedule} =
      CronSchedule.create(
        Map.merge(
          %{
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            name: "sched-#{System.unique_integer([:positive])}",
            cron_expression: "0 * * * *",
            reference: "reagent:local.test:1.0.0",
            resolved_reference: "reagent:local.test:1.0.0",
            profile_id: @profile_id,
            next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          attrs
        )
      )

    schedule
  end

  defp due!(schedule, seconds_ago \\ 60) do
    past = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in CronSchedule, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp occurrences(ctx, schedule) do
    {:ok, rows} = ScheduleOccurrences.list(ctx, schedule.id)
    rows
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    unless fun.() do
      if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
      Process.sleep(25)
      wait_until(fun, timeout)
    end
  end

  test "a due occurrence is one row, one execution, one background run on a worker service", %{
    ctx: ctx
  } do
    script!([{:probe, self()}, %{"ran" => true}])
    schedule = due!(create_schedule(ctx))
    scheduler!()

    assert_receive {:scripted_probe, runner, running_id}, 10_000

    assert Enum.any?(
             Cyfr.Execution.Semaphore.status().holders,
             &(&1.pid == inspect(Cyfr.Execution.Attempt.whereis(running_id)) and
                 &1.class == :background)
           )

    send(runner, :continue)
    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)

    assert [%{state: "completed", execution_id: execution_id, attempts: 1}] =
             occurrences(ctx, schedule)

    assert running_id == execution_id
    assert [%{execution_id: ^execution_id}] = ScriptedWorker.calls()

    assert {:ok, %{retention_class: "schedule"}, _bytes} =
             Arca.ExecutionPayloads.get(ctx, execution_id, "input")

    assert [%{id: ^execution_id, schedule_id: schedule_id, status: "completed"}] =
             Arca.Repo.all(Arca.Execution)

    assert schedule_id == schedule.id
    assert %{state: "completed"} = Arca.ExecutionAttempts.current(ctx.athanor_id, execution_id)

    # The cursor moved past the occurrence, and the row counts the run.
    wait_until(fn -> match?({:ok, %{run_count: 1}}, CronSchedule.get_for_daemon(schedule.id)) end)
    {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
    assert DateTime.compare(row.next_run_at, DateTime.utc_now()) == :gt
    assert row.last_execution_id == execution_id
  end

  test "a boot that does not own the control plane claims no occurrence, and fires once it does",
       %{ctx: ctx} do
    Cyfr.ControlPlane.mark(:lost)
    on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)

    script!([%{"ran" => true}])
    schedule = due!(create_schedule(ctx))
    pid = scheduler!()

    # The due timer fired on load and was deferred to the recheck.
    _ = :sys.get_state(pid)
    send(pid, {:fire, schedule.id})
    _ = :sys.get_state(pid)
    assert occurrences(ctx, schedule) == []
    assert ScriptedWorker.calls() == []

    Cyfr.ControlPlane.mark(:unclaimed)
    send(pid, {:fire, schedule.id})
    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
  end

  test "an admission that fails marks the occurrence failed without invoking anything", %{
    ctx: ctx
  } do
    script!([%{"ran" => true}])
    # A profile no consent source holds: the root is refused before admission.
    schedule = due!(create_schedule(ctx, %{profile_id: "prof_unconsented"}))
    scheduler!()

    wait_until(fn ->
      match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
    end)

    assert [%{state: "failed", execution_id: nil, attempts: 0}] = occurrences(ctx, schedule)
    assert [] = Arca.Repo.all(Arca.Execution)
    assert ScriptedWorker.calls() == []
  end

  test "a claimed occurrence nothing invoked runs once on recovery; a started one whose execution ended is uncertain",
       %{ctx: ctx} do
    script!([%{"ran" => true}])
    schedule = create_schedule(ctx)
    now = DateTime.utc_now()

    # Claimed by a scheduler that died before invoking.
    claimed =
      Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
        id: "occ_claimed",
        athanor_id: ctx.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(now, -120, :second),
        state: "claimed",
        claimed_by: "gone",
        claimed_at: now
      })

    # Started, and its execution has since ended without the occurrence.
    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(%{
        id: "exec_lapsed",
        reference: "reagent:local.test:1.0.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "reagent",
        schedule_id: schedule.id
      })

    {:ok, _} =
      Arca.Execution.record_end(
        ctx,
        "exec_lapsed",
        "failed",
        %{completed_at: now, duration_ms: 1, error_message: "swept"},
        attempt.attempt
      )

    Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
      id: "occ_started",
      athanor_id: ctx.athanor_id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.add(now, -60, :second),
      state: "started",
      execution_id: "exec_lapsed",
      attempts: 1,
      claimed_by: "gone",
      claimed_at: now
    })

    scheduler!()

    wait_until(fn ->
      match?({:ok, %{state: "completed"}}, ScheduleOccurrences.get(ctx, claimed.id))
    end)

    assert {:ok, %{state: "uncertain"}} = ScheduleOccurrences.get(ctx, "occ_started")
    assert {:ok, %{execution_id: execution_id}} = ScheduleOccurrences.get(ctx, claimed.id)
    assert [%{execution_id: ^execution_id}] = ScriptedWorker.calls()
    # The cursor is untouched: recovery re-runs a claim, it never claims anew.
    assert [_, _] = occurrences(ctx, schedule)
  end

  test "forbid leaves a due occurrence unclaimed while another is open; allow takes it", %{
    ctx: ctx
  } do
    forbid = due!(create_schedule(ctx, %{concurrency: "forbid"}))
    allow = due!(create_schedule(ctx, %{concurrency: "allow"}))
    now = DateTime.utc_now()

    for schedule <- [forbid, allow] do
      Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
        id: "occ_open_#{schedule.id}",
        athanor_id: ctx.athanor_id,
        schedule_id: schedule.id,
        scheduled_for: DateTime.add(now, -3600, :second),
        state: "started",
        execution_id: "exec_elsewhere",
        attempts: 1,
        claimed_by: "other-node",
        claimed_at: now
      })
    end

    next = DateTime.add(now, 3600, :second)

    assert :overlapping = ScheduleOccurrences.claim(forbid, "node-a", next)
    assert [%{state: "started"}] = occurrences(ctx, forbid)
    {:ok, row} = CronSchedule.get_for_daemon(forbid.id)
    assert DateTime.compare(row.next_run_at, forbid.next_run_at) == :eq

    assert {:ok, %{state: "claimed"}} = ScheduleOccurrences.claim(allow, "node-a", next)
    assert [_, _] = occurrences(ctx, allow)
  end

  test "a missed occurrence fires once", %{ctx: ctx} do
    script!([%{"ran" => true}])
    schedule = due!(create_schedule(ctx), 7_200)
    scheduler!()

    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
    Process.sleep(200)
    assert [_] = occurrences(ctx, schedule)
    assert [_] = ScriptedWorker.calls()
  end

  test "a runner that dies leaves a started occurrence uncertain", %{ctx: ctx} do
    script!([:hang])
    schedule = due!(create_schedule(ctx))
    pid = scheduler!()

    wait_until(fn -> map_size(:sys.get_state(pid).tasks) == 1 end)
    wait_until(fn -> match?([_], ScriptedWorker.calls()) end, 5_000)
    assert [%{state: "started"}] = occurrences(ctx, schedule)

    # The hung runner is killed underneath the scheduler.
    [task_pid] =
      for {_, p, _, _} <- Supervisor.which_children(Cyfr.Schedules.TaskSupervisor),
          is_pid(p),
          do: p

    Process.exit(task_pid, :kill)

    wait_until(fn -> match?([%{state: "uncertain"}], occurrences(ctx, schedule)) end)
  end

  test "the scheduler survives an unexpected message" do
    pid = scheduler!()

    assert capture_log(fn ->
             send(pid, :unexpected_test_message)
             :sys.get_state(pid)
           end) =~ "unexpected message"

    assert Process.alive?(pid)
  end
end
