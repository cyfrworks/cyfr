# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Cyfr.Bus.ScheduleCompleted
  alias Opus.Schedules.{Cron, Scheduler}
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.test"
  @profile_id "prof_test"
  @crash_email "planted-email-3f1a@example.test"
  @crash_input "planted-input-9c2e"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "scheduler_#{System.unique_integer([:positive])}")
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

    Sanctum.TestContext.ready!(ctx.athanor_id)
    component = consented!(ctx)
    {:ok, ctx: ctx, component: component}
  end

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

    granted!(ctx, component, [:interactive, :schedule])
    component
  end

  # The profile's head consent, admitting `origins`, written again over
  # whatever head it had.
  defp granted!(ctx, component, origins) do
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
        admitted_origins: origins,
        vault_refs: []
      })
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  # The scheduler under test, started after the rows it should find.
  defp scheduler!, do: start_supervised!(Scheduler)

  defp create_schedule(ctx, attrs \\ %{}) do
    {:ok, schedule} =
      CronSchedule.create(
        Sanctum.Context.actor(ctx),
        Map.merge(
          %{
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            name: "sched-#{System.unique_integer([:positive])}",
            cron_expression: "0 * * * *",
            reference: "reagent:local.test:1.0.0",
            resolved_reference: "reagent:local.test:1.0.0",
            profile_id: @profile_id,
            next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
            cap: 1_000
          },
          attrs
        )
      )

    schedule
  end

  # Due a few seconds ago: well within the missed bound, so the claim
  # fires it as an ordinary occurrence under either policy.
  defp due!(schedule, seconds_ago \\ 5) do
    past = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  # Not due for a day: no tick fires it until the case dues it again.
  defp park!(schedule) do
    later = DateTime.add(DateTime.utc_now(), 86_400, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: later]
      )

    %{schedule | next_run_at: later}
  end

  defp occurrences(ctx, schedule) do
    {:ok, rows} = ScheduleOccurrences.list(Sanctum.Context.actor(ctx), schedule.id, limit: 100)
    rows
  end

  # What the scheduler hands a claim of `schedule`.
  defp cadence(schedule) do
    {:ok, parsed} = Cron.parse(schedule.cron_expression)
    %{next_after: &Cron.next_run(parsed, &1), missed_bound_ms: Scheduler.missed_bound_ms()}
  end

  defp lose_ownership(loss) do
    value =
      if loss == :lost, do: :lost, else: {:held, 0}

    Arca.ControlPlane.record(value)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    Cyfr.Test.Sandbox.stop_work_on_exit()
  end

  defp running_task do
    [pid] =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Opus.Schedules.TaskSupervisor),
          is_pid(pid),
          do: pid

    pid
  end

  defp watch_outcomes do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:cyfr, :schedules, :completed], [:cyfr, :schedules, :failed]],
      fn event, _measurements, _metadata, test -> send(test, {:schedule_outcome, event}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)

    # And the committed completion the bus carries, which must follow the
    # same gates.
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
  end

  for loss <- [:lost, :expired], event <- [:completion, :death] do
    @tag :ownership_loss
    test "a scheduled #{event} after ownership is #{loss} leaves the occurrence and counters unchanged",
         %{ctx: ctx} do
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, execution_id}, 10_000
      _ = :sys.get_state(scheduler)
      task = running_task()
      ref = Process.monitor(task)
      watch_outcomes()

      if unquote(event) == :completion do
        true = :erlang.suspend_process(task)

        on_exit(fn ->
          if Process.alive?(task), do: :erlang.resume_process(task)
        end)

        send(worker, :continue)

        wait_until(fn ->
          match?(
            %{status: "completed"},
            Arca.Execution.get_tenant(Sanctum.Context.actor(ctx), execution_id)
          )
        end)
      end

      before = {CronSchedule.get_for_daemon(schedule.id), occurrences(ctx, schedule)}
      lose_ownership(unquote(loss))

      if unquote(event) == :completion,
        do: :erlang.resume_process(task),
        else: Process.exit(task, :kill)

      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      state = :sys.get_state(scheduler)
      assert is_integer(Process.read_timer(state.recovery_ref))
      assert Map.has_key?(state.timers, schedule.id)
      assert {CronSchedule.get_for_daemon(schedule.id), occurrences(ctx, schedule)} == before
      refute_received {:schedule_outcome, _}
      refute_received %ScheduleCompleted{}

      if unquote(event) == :completion do
        Arca.ControlPlane.record(:unclaimed)
        send(scheduler, :recover_occurrences)
        wait_until(fn -> match?([%{state: "uncertain"}], occurrences(ctx, schedule)) end)
        assert [%{execution_id: ^execution_id}] = ScriptedWorker.calls()
      end
    end
  end

  for loss <- [:lost, :expired] do
    @tag :ownership_loss
    test "a claimed occurrence starts no execution and is not failed after ownership is #{loss}",
         %{ctx: ctx} do
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      :ok = :sys.suspend(Opus.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Opus.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()
      wait_until(fn -> match?([%{state: "claimed"}], occurrences(ctx, schedule)) end)
      before = {CronSchedule.get_for_daemon(schedule.id), occurrences(ctx, schedule)}
      watch_outcomes()
      lose_ownership(unquote(loss))
      :ok = :sys.resume(Opus.Schedules.TaskSupervisor)
      wait_until(fn -> :sys.get_state(scheduler).tasks == %{} end)
      state = :sys.get_state(scheduler)
      assert is_integer(Process.read_timer(state.recovery_ref))
      assert Map.has_key?(state.timers, schedule.id)
      assert {CronSchedule.get_for_daemon(schedule.id), occurrences(ctx, schedule)} == before
      assert ScriptedWorker.calls() == []
      refute_received {:schedule_outcome, _}

      Arca.ControlPlane.record(:unclaimed)
      send(scheduler, :recover_occurrences)
      wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
      assert [_] = ScriptedWorker.calls()
    end
  end

  describe "the committed completion" do
    setup do
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    end

    test "is published once per completed occurrence, naming its athanor, after both writes",
         %{ctx: ctx} do
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      scheduler!()

      assert_receive %ScheduleCompleted{} = completion, 15_000
      assert completion == %ScheduleCompleted{kind: :completed, athanor_id: ctx.athanor_id}

      # Both writes were committed before it was said.
      assert [%{state: "completed", execution_id: execution_id}] = occurrences(ctx, schedule)

      assert {:ok, %{run_count: 1, last_execution_id: ^execution_id}} =
               CronSchedule.get_for_daemon(schedule.id)

      refute_receive %ScheduleCompleted{}, 300
    end

    test "is not published when recovery closed the occurrence first", %{ctx: ctx} do
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      _ = :sys.get_state(scheduler)
      task = running_task()
      ref = Process.monitor(task)

      # The occurrence is closed by another closer while the run is in
      # flight: the run's own finish moves no row.
      [%{id: occurrence_id, state: "started", claimed_by: claimed_by, execution_id: execution_id}] =
        occurrences(ctx, schedule)

      assert {:ok, 1} =
               ScheduleOccurrences.finish(
                 Sanctum.Context.actor(ctx),
                 occurrence_id,
                 claimed_by,
                 execution_id,
                 "uncertain"
               )

      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      _ = :sys.get_state(scheduler)

      assert [%{state: "uncertain"}] = occurrences(ctx, schedule)
      refute_received %ScheduleCompleted{}
    end

    test "is not published when the slot is lost after the writes and before the publish", %{
      ctx: ctx
    } do
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))

      # The run's telemetry fires in its own task, after the close and the
      # run record committed and before the publish's recheck: the slot is
      # lost exactly there.
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:cyfr, :schedules, :completed],
        fn _event, _measurements, _metadata, _config -> Arca.ControlPlane.record(:lost) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        Arca.ControlPlane.record(:unclaimed)
      end)

      Cyfr.Test.Sandbox.stop_work_on_exit()
      scheduler!()

      wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)

      wait_until(fn ->
        match?({:ok, %{run_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
      end)

      refute_receive %ScheduleCompleted{}, 300
    end
  end

  test "a due occurrence is one row, one execution, one background run on a worker service", %{
    ctx: ctx
  } do
    script!([{:probe, self()}, %{"ran" => true}])
    schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
    scheduler!()

    assert_receive {:scripted_probe, runner, running_id}, 10_000

    # The slot is held for the attempt by its slot holder, a process linked
    # to it.
    {:links, linked} = Process.info(Opus.Attempt.whereis(running_id), :links)
    held_for = Enum.map(linked, &inspect/1)

    assert Enum.any?(
             Prima.Slots.status(Opus.Slots).holders,
             &(&1.pid in held_for and &1.class == :background)
           )

    send(runner, :continue)
    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)

    assert [%{state: "completed", execution_id: execution_id, attempts: 1}] =
             occurrences(ctx, schedule)

    assert running_id == execution_id
    assert [%{execution_id: ^execution_id}] = ScriptedWorker.calls()

    assert {:ok, %{retention_class: "schedule"}, _bytes} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), execution_id, "input")

    assert [%{id: ^execution_id, schedule_id: schedule_id, status: "completed"}] =
             Arca.Repo.all(Arca.Schemas.Execution)

    assert schedule_id == schedule.id

    assert %{state: "completed"} =
             Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), execution_id)

    # The cursor moved past the occurrence, and the row counts the run.
    wait_until(fn -> match?({:ok, %{run_count: 1}}, CronSchedule.get_for_daemon(schedule.id)) end)
    {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
    assert DateTime.compare(row.next_run_at, DateTime.utc_now()) == :gt
    assert row.last_execution_id == execution_id
  end

  describe "the fire's decision" do
    defp fire_decisions do
      Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == "schedule"))
    end

    test "a fire is one admitted decision with its row, its run's execution and one completion",
         %{ctx: ctx} do
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      scheduler!()

      wait_until(fn -> match?([%{completion: "succeeded"}], fire_decisions()) end)

      assert [decision] = fire_decisions()
      assert "call_" <> _ = decision.call_id
      assert decision.action == "fire"
      assert decision.plane == "external"
      assert decision.admission == "admitted"
      assert decision.athanor_id == ctx.athanor_id
      assert decision.user_id == ctx.user_id
      assert %DateTime{} = decision.completed_at

      assert [row] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog, where: l.request_id == ^decision.request_id)
               )

      assert row.id == decision.call_id
      assert row.method == "cron/fire"
      assert row.status == "success"

      # The run the fire started names the decision it was admitted under.
      assert [%{state: "completed", execution_id: execution_id}] = occurrences(ctx, schedule)

      assert [%{id: ^execution_id, request_id: request_id}] =
               Arca.Repo.all(
                 from(e in Arca.Schemas.Execution, where: e.call_id == ^decision.call_id)
               )

      assert request_id == decision.request_id
    end

    test "a fire under a grant that does not name schedule invokes nothing until it does",
         %{ctx: ctx, component: component} do
      # The person's grant admits interactive alone.
      granted!(ctx, component, [:interactive])
      script!([%{"ran" => true}])
      # Its cadence's next time is half an hour away: only the fires this
      # case makes run it.
      schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
      pid = scheduler!()

      wait_until(fn ->
        match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
      end)

      assert [%{state: "failed", execution_id: nil, attempts: 0}] = occurrences(ctx, schedule)
      assert [] = Arca.Repo.all(Arca.Schemas.Execution)
      assert ScriptedWorker.calls() == []

      # Granted again naming schedule: the next fire runs, as a scheduled run.
      granted!(ctx, component, [:interactive, :schedule])
      _ = due!(schedule)
      send(pid, {:fire, schedule.id})

      wait_until(fn ->
        Enum.any?(occurrences(ctx, schedule), &(&1.state == "completed"))
      end)

      assert [%{origin: "schedule", schedule_id: schedule_id}] =
               Arca.Repo.all(Arca.Schemas.Execution)

      assert schedule_id == schedule.id
    end

    test "a fire whose admission fails is closed once, failed", %{ctx: ctx} do
      script!([%{"ran" => true}])

      schedule =
        due!(
          create_schedule(ctx, %{
            profile_id: "prof_unconsented",
            cron_expression: offset_hourly()
          })
        )

      scheduler!()

      wait_until(fn ->
        match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
      end)

      wait_until(fn -> match?([%{completion: "failed"}], fire_decisions()) end)
      assert [%{completion_class: class, admission: "admitted"}] = fire_decisions()
      assert is_binary(class)
    end
  end

  test "a boot that does not own the control plane claims no occurrence, and fires once it does",
       %{ctx: ctx} do
    # The row is written while this boot may write it; it then loses the
    # control plane before its scheduler starts.
    script!([%{"ran" => true}])
    schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
    Arca.ControlPlane.record(:lost)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
    pid = scheduler!()

    # The due timer fired on load and was deferred to the recheck.
    _ = :sys.get_state(pid)
    send(pid, {:fire, schedule.id})
    _ = :sys.get_state(pid)
    assert occurrences(ctx, schedule) == []
    assert ScriptedWorker.calls() == []

    Arca.ControlPlane.record(:unclaimed)
    send(pid, {:fire, schedule.id})
    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
  end

  test "an admission that fails marks the occurrence failed without invoking anything", %{
    ctx: ctx
  } do
    script!([%{"ran" => true}])
    # A profile no consent source holds: the root is refused before admission.
    schedule =
      due!(
        create_schedule(ctx, %{
          profile_id: "prof_unconsented",
          cron_expression: offset_hourly()
        })
      )

    scheduler!()

    wait_until(fn ->
      match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
    end)

    assert [%{state: "failed", execution_id: nil, attempts: 0}] = occurrences(ctx, schedule)
    assert [] = Arca.Repo.all(Arca.Schemas.Execution)
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

    # Started — a scheduled root is admitted only against its claimed
    # occurrence, which admission moves to `started` — and its execution
    # has since ended without the occurrence.
    Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
      id: "occ_started",
      athanor_id: ctx.athanor_id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.add(now, -60, :second),
      state: "claimed",
      claimed_by: Prima.Boot.id(),
      claimed_at: now
    })

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_lapsed",
          reference: "reagent:local.test:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          schedule_id: schedule.id,
          origin: :schedule
        },
        [occurrence_id: "occ_started"] ++ Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
      )

    {:ok, _} =
      Arca.Execution.record_end(
        Sanctum.Context.actor(ctx),
        "exec_lapsed",
        "failed",
        %{completed_at: now, duration_ms: 1, error_message: "swept"},
        attempt.attempt,
        Cyfr.Test.AttemptFixtures.stored()
      )

    scheduler!()

    wait_until(fn ->
      match?(
        {:ok, %{state: "completed"}},
        ScheduleOccurrences.get(Sanctum.Context.actor(ctx), claimed.id)
      )
    end)

    assert {:ok, %{state: "uncertain"}} =
             ScheduleOccurrences.get(Sanctum.Context.actor(ctx), "occ_started")

    assert {:ok, %{execution_id: execution_id}} =
             ScheduleOccurrences.get(Sanctum.Context.actor(ctx), claimed.id)

    assert [%{execution_id: ^execution_id}] = ScriptedWorker.calls()
    # The cursor is untouched: recovery re-runs a claim, it never claims anew.
    assert [_, _] = occurrences(ctx, schedule)
  end

  test "a claimed occurrence whose athanor no longer stands is not run on recovery, as the fire path would not",
       %{ctx: ctx} do
    script!([%{"ran" => true}])
    schedule = create_schedule(ctx)

    Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
      id: "occ_unstanding",
      athanor_id: ctx.athanor_id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second),
      state: "claimed",
      claimed_by: "gone",
      claimed_at: DateTime.utc_now()
    })

    # The athanor stops standing with no announcement: recovery reads it.
    Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id),
      set: [status: "archived"]
    )

    log =
      capture_log(fn ->
        scheduler!()

        wait_until(fn ->
          match?(
            {:ok, %{state: "failed"}},
            ScheduleOccurrences.get(Sanctum.Context.actor(ctx), "occ_unstanding")
          )
        end)
      end)

    assert log =~ "no longer active"
    assert ScriptedWorker.calls() == []
    assert [] = Arca.Repo.all(Arca.Schemas.Execution)
    assert {:ok, %{error_count: 1}} = CronSchedule.get_for_daemon(schedule.id)
  end

  test "a live peer's freshly claimed occurrence is left where it is", %{ctx: ctx} do
    script!([%{"ran" => true}])
    schedule = create_schedule(ctx)

    # A peer holding a slot of this cell, and an occurrence it claimed a
    # moment ago. The slot is this case's own node name, so nothing else
    # in the suite writes the row it measures.
    peer_node = "peer-#{System.unique_integer([:positive])}@cell"
    peer_boot = peer_node <> "#boot_a"
    assert {:ok, _} = Arca.ControlPlane.take(peer_node, peer_boot, 60_000)
    # `take/3` recorded the peer's generation in this member's term; a
    # later boot test in the same VM reads "no slot, known generation" as
    # `:slot_not_held`, so the generation is forgotten with the slot.
    Arca.ControlPlane.record(:unclaimed)
    Arca.ControlPlane.forget()
    Arca.ControlPlane.forget_generation()

    Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
      id: "occ_peers",
      athanor_id: ctx.athanor_id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.add(DateTime.utc_now(), -120, :second),
      state: "claimed",
      claimed_by: peer_boot,
      claimed_at: Arca.ServerMetaStorage.now!()
    })

    pid = scheduler!()
    # The boot recovery pass has run by the time the server answers.
    _ = :sys.get_state(pid)

    assert {:ok, %{state: "claimed", claimed_by: ^peer_boot}} =
             ScheduleOccurrences.get(Sanctum.Context.actor(ctx), "occ_peers")

    assert ScriptedWorker.calls() == []
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

    assert :overlapping = ScheduleOccurrences.claim(forbid, "node-a", cadence(forbid))
    assert [%{state: "started"}] = occurrences(ctx, forbid)
    {:ok, row} = CronSchedule.get_for_daemon(forbid.id)
    assert DateTime.compare(row.next_run_at, forbid.next_run_at) == :eq

    assert {:ok, %{state: "claimed"}} = ScheduleOccurrences.claim(allow, "node-a", cadence(allow))
    assert [_, _] = occurrences(ctx, allow)
  end

  test "a missed occurrence fires once under catch_up with a limit of 1, and not at all under skip",
       %{ctx: ctx} do
    script!([%{"ran" => true}])

    # An expression whose next time is half an hour away whenever the case
    # runs: no time of either cadence comes due while it does, so the
    # occurrences are the missed run's alone.
    once =
      due!(
        create_schedule(ctx, %{
          cron_expression: offset_hourly(),
          missed_runs: "catch_up",
          catch_up_limit: 1
        }),
        7_200
      )

    skipped = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}), 7_200)
    scheduler = scheduler!()

    # The first tick's run, and the cursor it moves, under the suite's load:
    # bounded as the other runs of this file are.
    wait_until(
      fn -> match?([%{state: "completed"}], occurrences(ctx, once)) end,
      30_000,
      "the missed run to complete under catch_up"
    )

    wait_until(
      fn ->
        {:ok, row} = CronSchedule.get_for_daemon(skipped.id)
        DateTime.compare(row.next_run_at, skipped.next_run_at) == :gt
      end,
      30_000,
      "the skipped schedule's cursor to move past its missed times"
    )

    for schedule <- [once, skipped], do: send(scheduler, {:fire, schedule.id})
    _ = :sys.get_state(scheduler)
    assert [%{scheduled_for: fired}] = occurrences(ctx, once)
    assert DateTime.compare(fired, once.next_run_at) == :eq
    assert [] = occurrences(ctx, skipped)
    assert [_] = ScriptedWorker.calls()
  end

  describe "missed runs" do
    # An hourly expression at the minute half an hour from now: its last
    # missed time is about half an hour ago and its next about half an
    # hour ahead, whenever the case runs. A case that dues a schedule and
    # then asserts on its exact occurrences names it too: no tick of the
    # expression comes due while the case runs.
    defp offset_hourly do
      minute = DateTime.add(DateTime.utc_now(), 1_800, :second).minute
      "#{minute} * * * *"
    end

    # A schedule of `attrs` whose cursor is `missed` of its expression's
    # times behind: the oldest of them.
    defp missed!(ctx, missed, attrs) do
      schedule = create_schedule(ctx, Map.merge(%{cron_expression: offset_hourly()}, attrs))
      {:ok, parsed} = Cron.parse(schedule.cron_expression)
      {:ok, last} = Cron.next_run(parsed, DateTime.add(DateTime.utc_now(), -3_600, :second))
      cursor = DateTime.add(last, -(missed - 1) * 3_600, :second)

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
          set: [next_run_at: cursor]
        )

      %{schedule | next_run_at: cursor}
    end

    defp row!(schedule) do
      {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
      row
    end

    defp fired_times(ctx, schedule) do
      ctx |> occurrences(schedule) |> Enum.map(& &1.scheduled_for) |> Enum.sort(DateTime)
    end

    defp hours_after(time, n), do: DateTime.add(time, n * 3_600, :second)

    test "a downtime of 10 missed times under catch_up 3 fires exactly 3 over repeated ticks, then resumes after now",
         %{ctx: ctx} do
      script!(List.duplicate(%{"ran" => true}, 3))

      schedule =
        missed!(ctx, 10, %{concurrency: "allow", missed_runs: "catch_up", catch_up_limit: 3})

      scheduler = scheduler!()

      wait_until(fn ->
        match?([_, _, _], occurrences(ctx, schedule)) and row!(schedule).catch_up_left == 0
      end)

      for _tick <- 1..3 do
        send(scheduler, {:fire, schedule.id})
        _ = :sys.get_state(scheduler)
      end

      wait_until(fn -> Enum.all?(occurrences(ctx, schedule), &(&1.state == "completed")) end)

      assert fired_times(ctx, schedule) ==
               for(n <- 0..2, do: hours_after(schedule.next_run_at, n))

      assert length(ScriptedWorker.calls()) == 3

      row = row!(schedule)
      assert {row.catch_up_until, row.catch_up_left} == {nil, 0}
      assert DateTime.compare(row.next_run_at, DateTime.utc_now()) == :gt
    end

    test "a restart between the second and the third catch-up fire resumes from the row and fires the third once",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      schedule = missed!(ctx, 10, %{missed_runs: "catch_up", catch_up_limit: 3})

      # The member that fired the first two is gone: what it left is the
      # row's cursor and episode, and its two ended occurrences.
      for _ <- 1..2 do
        {:ok, occurrence} =
          ScheduleOccurrences.claim(row!(schedule), "boot-gone", cadence(schedule))

        {:ok, 1} = ScheduleOccurrences.finish(actor, occurrence.id, "boot-gone", nil, "completed")
      end

      assert %{catch_up_left: 1, catch_up_until: %DateTime{}} = row!(schedule)

      script!([%{"ran" => true}])
      scheduler = scheduler!()

      wait_until(fn ->
        length(occurrences(ctx, schedule)) == 3 and row!(schedule).catch_up_left == 0
      end)

      send(scheduler, {:fire, schedule.id})
      _ = :sys.get_state(scheduler)

      assert fired_times(ctx, schedule) ==
               for(n <- 0..2, do: hours_after(schedule.next_run_at, n))

      wait_until(fn -> length(ScriptedWorker.calls()) == 1 end)
      assert DateTime.compare(row!(schedule).next_run_at, DateTime.utc_now()) == :gt
    end

    test "a skip schedule whose timer fires within the jitter after its due time fires once, every time",
         %{ctx: ctx} do
      # The scheduler adds up to 30 s to a timer (`jitter_ms/1`); a fire
      # that late, or a little later still, is the ordinary occurrence.
      lateness = [1, 15, 29, 30, 33]
      script!(List.duplicate(%{"ran" => true}, length(lateness)))

      late =
        for seconds <- lateness,
            do: due!(create_schedule(ctx, %{cron_expression: offset_hourly()}), seconds)

      # Past the bound it is a missed time, and skip skips it.
      missed = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}), 40)
      scheduler = scheduler!()

      wait_until(fn ->
        Enum.all?(late, &match?([%{state: "completed"}], occurrences(ctx, &1)))
      end)

      for schedule <- [missed | late], do: send(scheduler, {:fire, schedule.id})
      _ = :sys.get_state(scheduler)

      for schedule <- late do
        assert fired_times(ctx, schedule) == [schedule.next_run_at]
      end

      assert fired_times(ctx, missed) == []
      assert DateTime.compare(row!(missed).next_run_at, DateTime.utc_now()) == :gt
      assert length(ScriptedWorker.calls()) == length(lateness)
    end

    @tag timeout: 120_000
    test "a stop and restart across several due times under skip skips only the missed ones and fires the next ordinary one",
         %{ctx: ctx} do
      script!([%{"ran" => true}])
      # Every minute: the next ordinary time is within the bound or less
      # than half a minute ahead, so the case waits at most that long.
      schedule = create_schedule(ctx, %{cron_expression: "* * * * *"})
      stopped_at = DateTime.add(DateTime.utc_now(), -6 * 60, :second)

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
          set: [next_run_at: stopped_at]
        )

      started = DateTime.utc_now()
      _scheduler = scheduler!()

      wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end, 45_000)

      assert [fired] = fired_times(ctx, schedule)
      bound = Scheduler.missed_bound_ms()
      assert DateTime.diff(fired, started, :millisecond) > -bound
      assert length(ScriptedWorker.calls()) == 1
    end

    test "a walk across both daylight-saving changes fires each UTC time once, and a cursor set back to a fired time fires nothing again",
         %{ctx: ctx} do
      # Expressions are UTC: the weeks around the American (8 March) and
      # European (29 March) changes are 24 hours apart day by day.
      schedule =
        create_schedule(ctx, %{
          cron_expression: "30 1 * * *",
          concurrency: "allow",
          missed_runs: "catch_up",
          catch_up_limit: Scheduler.max_catch_up()
        })

      first = ~U[2026-03-06 01:30:00.000000Z]

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
          set: [next_run_at: first]
        )

      for _ <- 1..Scheduler.max_catch_up() do
        assert {:ok, _} = ScheduleOccurrences.claim(row!(schedule), "node-a", cadence(schedule))
      end

      fired = fired_times(ctx, schedule)
      assert fired == for(n <- 0..23, do: DateTime.add(first, n * 86_400, :second))
      assert row!(schedule).catch_up_left == 0
      assert :held = ScheduleOccurrences.claim(row!(schedule), "node-a", cadence(schedule))

      # A clock set back can leave a cursor naming a time that fired; it
      # is moved past, and fires nothing.
      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
          set: [next_run_at: List.last(fired)]
        )

      assert :held = ScheduleOccurrences.claim(row!(schedule), "node-b", cadence(schedule))
      assert fired_times(ctx, schedule) == fired
      assert DateTime.compare(row!(schedule).next_run_at, List.last(fired)) == :gt
    end

    test "a forbid time held past the bound by an overrunning run is dropped under skip and fired within the limit under catch_up",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      bound = Scheduler.missed_bound_ms()

      held =
        for attrs <- [%{}, %{missed_runs: "catch_up", catch_up_limit: 1}] do
          schedule = create_schedule(ctx, Map.merge(%{concurrency: "forbid"}, attrs))

          # The run of the time before is still going.
          Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
            id: "occ_overrun_#{schedule.id}",
            athanor_id: ctx.athanor_id,
            schedule_id: schedule.id,
            scheduled_for: DateTime.add(DateTime.utc_now(), -3_600, :second),
            state: "claimed",
            claimed_by: "boot-overrun",
            claimed_at: Arca.ServerMetaStorage.now!()
          })

          # Due within the bound, the time waits behind the run under
          # either policy.
          due = due!(schedule)
          assert :overlapping = ScheduleOccurrences.claim(due, "node-a", cadence(due))
          due
        end

      # The run overran: by the time the scheduler looks again, the time
      # it held back is older than the bound.
      [skip, catch_up] =
        for schedule <- held do
          late = DateTime.add(Arca.ServerMetaStorage.now!(), -(bound + 5_000), :millisecond)

          {1, _} =
            Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
              set: [next_run_at: late]
            )

          %{schedule | next_run_at: late}
        end

      # Under skip it is dropped, though the run is still going.
      assert :skipped = ScheduleOccurrences.claim(skip, "node-a", cadence(skip))
      refute Enum.any?(fired_times(ctx, skip), &(DateTime.compare(&1, skip.next_run_at) == :eq))
      assert DateTime.compare(row!(skip).next_run_at, skip.next_run_at) == :gt

      # Under catch_up it still waits for the run, then fires once it ends.
      assert :overlapping = ScheduleOccurrences.claim(catch_up, "node-a", cadence(catch_up))

      {:ok, 1} =
        ScheduleOccurrences.finish(
          actor,
          "occ_overrun_#{catch_up.id}",
          "boot-overrun",
          nil,
          "completed"
        )

      assert {:ok, %{scheduled_for: fired}} =
               ScheduleOccurrences.claim(row!(catch_up), "node-a", cadence(catch_up))

      assert DateTime.compare(fired, catch_up.next_run_at) == :eq

      # The limit of 1 is spent: the episode closed on the first time not missed.
      row = row!(catch_up)
      assert {row.catch_up_until, row.catch_up_left} == {nil, 0}
      assert DateTime.compare(row.next_run_at, catch_up.next_run_at) == :gt
    end

    test "the catch-up ceiling is the table's: max_catch_up/0 is accepted and one more refused",
         %{ctx: ctx} do
      assert Scheduler.max_catch_up() == 24
      create_schedule(ctx, %{missed_runs: "catch_up", catch_up_limit: Scheduler.max_catch_up()})

      assert {:error, {:validation, %{catch_up_limit: [_ | _]}}} =
               CronSchedule.create(Sanctum.Context.actor(ctx), %{
                 user_id: ctx.user_id,
                 athanor_id: ctx.athanor_id,
                 name: "over-#{System.unique_integer([:positive])}",
                 cron_expression: "0 * * * *",
                 reference: "reagent:local.test:1.0.0",
                 resolved_reference: "reagent:local.test:1.0.0",
                 profile_id: @profile_id,
                 missed_runs: "catch_up",
                 catch_up_limit: Scheduler.max_catch_up() + 1,
                 cap: 1_000
               })
    end

    test "the missed bound is the larger of the jitter cap and the slot lease, with the delivery slack" do
      assert Scheduler.missed_bound_ms() == max(30_000, Cyfr.Cell.lease_ms()) + 5_000
    end
  end

  test "a runner that dies leaves a started occurrence uncertain", %{ctx: ctx} do
    script!([:hang])
    schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
    pid = scheduler!()

    wait_until(fn -> map_size(:sys.get_state(pid).tasks) == 1 end)
    wait_until(fn -> match?([_], ScriptedWorker.calls()) end, 5_000)
    assert [%{state: "started"}] = occurrences(ctx, schedule)

    # The hung runner is killed underneath the scheduler.
    [task_pid] =
      for {_, p, _, _} <- Supervisor.which_children(Opus.Schedules.TaskSupervisor),
          is_pid(p),
          do: p

    Process.exit(task_pid, :kill)

    wait_until(fn -> match?([%{state: "uncertain"}], occurrences(ctx, schedule)) end)
  end

  # A run that crashes exits with its stacktrace, whose failing frame holds
  # the arguments `run/6` was called with: the schedule's context and input.
  test "a runner that crashes is logged by its frames' arity, never their arguments", %{
    ctx: ctx
  } do
    script!([:hang])
    schedule = due!(create_schedule(ctx, %{cron_expression: offset_hourly()}))
    pid = scheduler!()

    wait_until(fn -> map_size(:sys.get_state(pid).tasks) == 1 end)
    wait_until(fn -> match?([_], ScriptedWorker.calls()) end, 5_000)

    [task_pid] =
      for {_, p, _, _} <- Supervisor.which_children(Opus.Schedules.TaskSupervisor),
          is_pid(p),
          do: p

    args = [schedule, %{id: "occ"}, %{email: @crash_email}, @reference, @crash_input, 1]
    frame = {Scheduler, :run, args, [file: ~c"lib/opus/schedules/scheduler.ex", line: 1]}

    log =
      capture_log(fn ->
        Process.exit(task_pid, {:function_clause, [frame]})
        wait_until(fn -> match?([%{state: "uncertain"}], occurrences(ctx, schedule)) end)
      end)

    refute log =~ @crash_email
    refute log =~ @crash_input
    assert log =~ "execution failed: {:function_clause, [{Opus.Schedules.Scheduler, :run, 6,"
  end

  test "the scheduler survives an unexpected message" do
    pid = scheduler!()

    assert capture_log(fn ->
             send(pid, :unexpected_test_message)
             :sys.get_state(pid)
           end) =~ "unexpected message"

    assert Process.alive?(pid)
  end

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream that tells the test what it was sent.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:upstream, %{path: conn.request_path, headers: conn.req_headers}})
      Plug.Conn.send_resp(conn, 200, "scheduled upstream")
    end
  end

  @attached_probe Path.expand(
                    "../../../../locus/test/support/runtime/test_wasm/hostile/attached_header_probe.wasm",
                    __DIR__
                  )
  @attached_secret "sk-scheduled-e7-canary-41d9b0"

  describe "a scheduled attached request" do
    # The probe of the runtime's hostile guests that sends its input as its one
    # request, published as a component of the person's own whose need
    # `api_key` CYFR attaches by header, its entry bound until `until` under
    # a consent that admits scheduled runs. Answers its reference and the
    # profile schedules name.
    defp attached_probe!(ctx, port, until) do
      walk = Sanctum.TestContext.via(ctx, :prism)
      name = "scheduled-probe-#{System.unique_integer([:positive])}"

      manifest = %{
        "name" => name,
        "version" => "1.0.0",
        "type" => "catalyst",
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:upstream.test",
            "reason" => "to call the upstream with your key",
            "fields" => ["KEY"],
            "attach" => %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}
          }
        },
        "caps" => %{
          "egress" => %{
            "domains" => ["127.0.0.1"],
            "methods" => ["GET"],
            "schemes" => ["http"],
            "private_ips" => ["127.0.0.1"]
          }
        }
      }

      {:ok, _component} =
        Compendium.Registry.publish_bytes(walk, File.read!(@attached_probe), %{
          name: name,
          version: "1.0.0",
          type: "catalyst",
          manifest: Jason.encode!(manifest)
        })

      {:ok, entry} =
        Sanctum.TestContext.create_vault(walk, %{
          name: "#{name} key",
          kind: "api_key",
          provider_hint: "upstream.test",
          fields: %{"KEY" => @attached_secret},
          destination: %{"hosts" => ["127.0.0.1"], "scheme" => "http", "port" => port}
        })

      ref = "catalyst:local." <> name

      decisions = %{
        ref: ref,
        bindings: [
          %{
            need: "api_key",
            entry_id: entry.id,
            lifetime: %{kind: "until", until: DateTime.to_iso8601(until)}
          }
        ],
        origins: [:interactive, :schedule]
      }

      {:ok, plan} = Sanctum.Consent.Plan.plan(walk, %{ref: ref})
      {:ok, preview} = Sanctum.Consent.Commit.preview(walk, decisions)

      {:ok, %{profile_id: profile_id}} =
        Sanctum.Consent.Commit.commit(walk, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      {ref <> ":1.0.0", profile_id}
    end

    # What the guest of `execution_id` answered as its runner closed it,
    # read once the suite's wire has recorded that call.
    defp scheduled_answer(execution_id) do
      Cyfr.Test.TwoServices.settled!()

      [%{args: %{"outcome" => %{"output" => output}}}] =
        Cyfr.Test.TwoServices.calls(:complete, execution_id)

      output
    end

    test "a scheduled attached request succeeds before expiry and is refused after it", %{
      ctx: ctx
    } do
      upstream =
        start_supervised!(
          {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
      Cyfr.Test.TwoServices.watch!()

      until = DateTime.utc_now() |> DateTime.add(8, :second) |> DateTime.truncate(:second)
      {reference, profile_id} = attached_probe!(ctx, port, until)

      input = %{
        "connection" => "api_key",
        "method" => "GET",
        "url" => "http://127.0.0.1:#{port}/scheduled"
      }

      # Its cadence's next time is half an hour away: only the fires this
      # case makes run it.
      schedule =
        due!(
          create_schedule(ctx, %{
            cron_expression: offset_hourly(),
            reference: reference,
            resolved_reference: reference,
            profile_id: profile_id,
            input: Jason.encode!(input)
          })
        )

      pid = scheduler!()

      # Before the instant: the fire runs the probe in a runner, and CYFR
      # attaches the key to its request.
      wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end, 30_000)
      assert [%{execution_id: first}] = occurrences(ctx, schedule)
      assert %{"status" => 200, "body" => "scheduled upstream"} = scheduled_answer(first)
      assert_receive {:upstream, sent}, 5_000
      assert sent.path == "/scheduled" and {"x-api-key", @attached_secret} in sent.headers

      # Held across the binding's instant: no tick fires the schedule while
      # the case waits it out, so the one fire after it is the case's own.
      park!(schedule)

      wait_until(
        fn -> DateTime.compare(DateTime.utc_now(), until) == :gt end,
        15_000,
        "the binding's instant to pass"
      )

      # After it: the next fire is admitted and its request refused before
      # any upstream request.
      _ = due!(schedule)
      send(pid, {:fire, schedule.id})

      wait_until(fn -> Enum.any?(occurrences(ctx, schedule), &(&1.state == "failed")) end, 30_000)
      [%{execution_id: second}] = Enum.filter(occurrences(ctx, schedule), &(&1.state == "failed"))

      assert %{"error" => %{"type" => "grant_expired", "message" => message}} =
               scheduled_answer(second)

      assert message == Prima.Refusal.message(:grant_expired)
      refute_received {:upstream, _sent}
    end
  end
end
