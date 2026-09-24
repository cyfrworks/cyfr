# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Schedules.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Cyfr.Bus.ScheduleCompleted
  alias Crucible.Schedules.Scheduler
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "reagent:local.test"
  @profile_id "prof_test"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "scheduler_#{System.unique_integer([:positive])}")
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
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^schedule.id),
        set: [next_run_at: past]
      )

    %{schedule | next_run_at: past}
  end

  defp occurrences(ctx, schedule) do
    {:ok, rows} = ScheduleOccurrences.list(Sanctum.Context.actor(ctx), schedule.id)
    rows
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
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Crucible.Schedules.TaskSupervisor),
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
      schedule = due!(create_schedule(ctx))
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
      schedule = due!(create_schedule(ctx))
      :ok = :sys.suspend(Crucible.Schedules.TaskSupervisor)
      on_exit(fn -> :sys.resume(Crucible.Schedules.TaskSupervisor) end)
      scheduler = scheduler!()
      wait_until(fn -> match?([%{state: "claimed"}], occurrences(ctx, schedule)) end)
      before = {CronSchedule.get_for_daemon(schedule.id), occurrences(ctx, schedule)}
      watch_outcomes()
      lose_ownership(unquote(loss))
      :ok = :sys.resume(Crucible.Schedules.TaskSupervisor)
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

      # The notes keeper hears every completion this suite publishes; its
      # write is done before the test gives its sandbox back.
      on_exit(fn -> :sys.get_state(Aqua.ScheduleNotes) end)
      :ok
    end

    test "is published once per completed occurrence, after both writes, from this member", %{
      ctx: ctx
    } do
      script!([%{"ran" => true}])

      schedule =
        due!(
          create_schedule(ctx, %{metadata: ~s({"keep_outcome": true, "note_name": "nightly"})})
        )

      scheduler!()

      assert_receive %ScheduleCompleted{schedule_id: schedule_id} = completion, 15_000
      assert schedule_id == schedule.id

      # Both writes were committed before it was said.
      assert [%{state: "completed", id: occurrence_id, execution_id: execution_id}] =
               occurrences(ctx, schedule)

      assert {:ok, %{run_count: 1, last_execution_id: ^execution_id}} =
               CronSchedule.get_for_daemon(schedule.id)

      assert completion.occurrence_id == occurrence_id
      assert completion.execution_id == execution_id
      assert completion.athanor_id == ctx.athanor_id
      assert completion.actor.athanor_id == ctx.athanor_id
      assert completion.keep_outcome and completion.note_name == "nightly"
      assert is_binary(completion.output) and completion.output =~ "ran"
      assert %DateTime{} = completion.completed_at
      # No claimant runs in this suite: the issuer is the member's `:none`.
      assert completion.issuer_member == ScheduleCompleted.issuer(Arca.ControlPlane.held())

      refute_receive %ScheduleCompleted{}, 300
    end

    test "carries no output for a schedule that did not ask to keep it", %{ctx: ctx} do
      script!([%{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler!()

      assert_receive %ScheduleCompleted{schedule_id: id, keep_outcome: false, output: nil}, 15_000
      assert id == schedule.id
    end

    test "is not published when recovery closed the occurrence first", %{ctx: ctx} do
      script!([{:probe, self()}, %{"ran" => true}])
      schedule = due!(create_schedule(ctx))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      _ = :sys.get_state(scheduler)
      task = running_task()
      ref = Process.monitor(task)

      # The occurrence is closed by another closer while the run is in
      # flight: the run's own finish moves no row.
      [%{id: occurrence_id, state: "started"}] = occurrences(ctx, schedule)

      assert {:ok, 1} =
               ScheduleOccurrences.finish(Sanctum.Context.actor(ctx), occurrence_id, "uncertain")

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
      schedule = due!(create_schedule(ctx))

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
    schedule = due!(create_schedule(ctx))
    scheduler!()

    assert_receive {:scripted_probe, runner, running_id}, 10_000

    # The slot is held for the attempt by its slot holder, a process linked
    # to it.
    {:links, linked} = Process.info(Crucible.Attempt.whereis(running_id), :links)
    held_for = Enum.map(linked, &inspect/1)

    assert Enum.any?(
             Prima.Slots.status(Crucible.Slots).holders,
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

  test "a boot that does not own the control plane claims no occurrence, and fires once it does",
       %{ctx: ctx} do
    Arca.ControlPlane.record(:lost)
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

    script!([%{"ran" => true}])
    schedule = due!(create_schedule(ctx))
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
    schedule = due!(create_schedule(ctx, %{profile_id: "prof_unconsented"}))
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

    # Started, and its execution has since ended without the occurrence.
    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_lapsed",
          reference: "reagent:local.test:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          schedule_id: schedule.id
        },
        Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
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

    # The estate stops standing with no announcement: recovery reads it.
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
    scheduler = scheduler!()

    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
    send(scheduler, {:fire, schedule.id})
    _ = :sys.get_state(scheduler)
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
      for {_, p, _, _} <- Supervisor.which_children(Crucible.Schedules.TaskSupervisor),
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
