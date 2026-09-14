# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Schedules.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Schedules.Scheduler

  # The execution port, answering as the engine would for the scheduler:
  # admission is the one place an occurrence is joined to its execution,
  # and the engine's answer is what closes it. `:refuse` refuses
  # admission (nothing is admitted); `:hang` never answers.
  defmodule Engine do
    @behaviour Cyfr.Execution

    def calls, do: Agent.get(__MODULE__, & &1)

    def run_root(ctx, _selector, reference, input, opts) do
      Agent.update(__MODULE__, &[%{reference: reference, input: input, opts: opts} | &1])

      case Application.get_env(:cyfr, :schedules_test_engine, :complete) do
        :refuse ->
          {:error, :refused}

        :hang ->
          Process.sleep(:infinity)

        :complete ->
          {:ok, %{attempt: attempt}} =
            Arca.Execution.admit(
              %{
                id: Keyword.fetch!(opts, :execution_id),
                reference: reference,
                user_id: ctx.user_id,
                athanor_id: ctx.athanor_id,
                component_type: "reagent",
                schedule_id: Keyword.fetch!(opts, :schedule_id)
              },
              occurrence_id: Keyword.fetch!(opts, :occurrence_id)
            )

          {:ok, _} =
            Arca.Execution.record_end(
              ctx,
              Keyword.fetch!(opts, :execution_id),
              "completed",
              %{completed_at: DateTime.utc_now(), duration_ms: 1, output: ~s({"ran":true})},
              attempt.attempt
            )

          {:ok, %{output: %{"ran" => true}}}
      end
    end

    def run_root_edge(_ctx, _src, _ref, _input, _opts), do: {:error, :unsupported}
    def authority_for(_ctx, _sel, _ref, _opts), do: {:error, :unsupported}
    def subscribe_events(_id, _ctx), do: :ok
    def unsubscribe_events(_id, _ctx), do: :ok
    def events_since(_id, _seq, _athanor), do: []
    def run_child(_authority, _ref, _need, _input, _opts), do: {:error, :unsupported}
    def claim_turn_root(_ctx, _ref, _opts), do: {:error, :unsupported}
    def pause_turn_root(_ctx, _id, _opts), do: {:error, :unsupported}
    def resume_turn_root(_ctx, _id, _opts), do: {:error, :unsupported}
    def adopt_turn_root(_ctx, _id, _opts), do: {:error, :unsupported}
    def release_turn_root(_ctx, _id, _opts), do: :ok
    def cancel(_ctx, _id), do: {:error, :unsupported}
    def cancel_for_restart(_ctx, _id, _payload), do: {:error, :unsupported}
    def get(_ctx, _id), do: {:error, :not_found}
    def list(_ctx, _opts), do: {:ok, []}
    def ready?, do: true
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    keys = [:cron_scheduler_enabled, :execution_impl, :schedules_test_engine]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)
    Application.put_env(:cyfr, :execution_impl, Engine)
    Application.put_env(:cyfr, :schedules_test_engine, :complete)

    on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    start_supervised!(%{id: Engine, start: {Agent, :start_link, [fn -> [] end, [name: Engine]]}})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

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
            profile_id: "prof_test",
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

  test "a due occurrence is one row, one execution, one invocation through the port", %{
    ctx: ctx
  } do
    schedule = due!(create_schedule(ctx))
    scheduler!()

    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)

    assert [%{state: "completed", execution_id: execution_id, attempts: 1}] =
             occurrences(ctx, schedule)

    assert [%{opts: opts}] = Engine.calls()
    assert Keyword.fetch!(opts, :execution_id) == execution_id
    assert Keyword.fetch!(opts, :schedule_id) == schedule.id
    assert Keyword.fetch!(opts, :retention_class) == "schedule"
    assert Keyword.fetch!(opts, :class) == :background

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

    schedule = due!(create_schedule(ctx))
    pid = scheduler!()

    # The due timer fired on load and was deferred to the recheck.
    _ = :sys.get_state(pid)
    send(pid, {:fire, schedule.id})
    _ = :sys.get_state(pid)
    assert occurrences(ctx, schedule) == []
    assert Engine.calls() == []

    Cyfr.ControlPlane.mark(:unclaimed)
    send(pid, {:fire, schedule.id})
    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
  end

  test "an admission that fails marks the occurrence failed without invoking anything", %{
    ctx: ctx
  } do
    Application.put_env(:cyfr, :schedules_test_engine, :refuse)
    schedule = due!(create_schedule(ctx))
    scheduler!()

    wait_until(fn ->
      match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(schedule.id))
    end)

    assert [%{state: "failed", execution_id: nil, attempts: 0}] = occurrences(ctx, schedule)
    assert [] = Arca.Repo.all(Arca.Execution)
  end

  test "a claimed occurrence nothing invoked runs once on recovery; a started one whose execution ended is uncertain",
       %{ctx: ctx} do
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
    assert [%{opts: opts}] = Engine.calls()
    assert Keyword.fetch!(opts, :occurrence_id) == claimed.id
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
    schedule = due!(create_schedule(ctx), 7_200)
    scheduler!()

    wait_until(fn -> match?([%{state: "completed"}], occurrences(ctx, schedule)) end)
    Process.sleep(200)
    assert [_] = occurrences(ctx, schedule)
    assert [_] = Engine.calls()
  end

  test "a runner that dies leaves a started occurrence uncertain", %{ctx: ctx} do
    Application.put_env(:cyfr, :schedules_test_engine, :hang)
    schedule = due!(create_schedule(ctx))
    pid = scheduler!()

    wait_until(fn -> map_size(:sys.get_state(pid).tasks) == 1 end)
    {:ok, _} = admit_for_hung!(ctx, schedule)

    # The hung runner is killed underneath the scheduler.
    [task_pid] =
      for {_, p, _, _} <- Supervisor.which_children(Cyfr.Schedules.TaskSupervisor),
          is_pid(p),
          do: p

    Process.exit(task_pid, :kill)

    wait_until(fn -> match?([%{state: "uncertain"}], occurrences(ctx, schedule)) end)
  end

  # The hung engine never admitted; a started occurrence is what an
  # admission leaves, so it is written here as the engine would.
  defp admit_for_hung!(ctx, schedule) do
    [occurrence] = occurrences(ctx, schedule)

    Arca.Execution.admit(
      %{
        id: "exec_hung",
        reference: "reagent:local.test:1.0.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "reagent",
        schedule_id: schedule.id
      },
      occurrence_id: occurrence.id
    )
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
