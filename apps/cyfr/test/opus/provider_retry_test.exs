# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ProviderRetryTest do
  @moduledoc """
  `execution.retry` through the gate: a failed run of the caller's athanor
  that a schedule or a feed started runs again as a new root with the
  same pinned component, input and profile, at the consent revision it
  ran at, as the caller's own run, answered accepted once it starts and
  ending as the run's own events say. Another athanor's run, a run that did
  not fail, one started anywhere but a schedule or a feed, one whose input
  is no longer kept and one whose grant has changed since are refused,
  and nothing runs.

  Runs use the scripted worker service: everything but the component is
  real.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Cyfr.Test.Cron, only: [hourly_away: 0]

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Schedules.{Cron, Scheduler}
  alias Opus.Record
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "catalyst:local.retried"
  @pinned "catalyst:local.retried:1.0.0"
  @profile_id "prof_retry_tool"
  @consent "consent-#{@profile_id}"
  @input %{"city" => "Lisbon", "days" => 3}

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "retry_tool_#{System.unique_integer([:positive])}")
    configured = Application.get_env(:cyfr, :locus_runtime_workers)

    Prima.Test.Env.put_app_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers(@reference, configured)
    )

    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    ctx = Sanctum.TestContext.local(:prism)

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    digest = published!(ctx)
    consented!(ctx, digest, @consent)
    {:ok, ctx: ctx, digest: digest}
  end

  describe "the declaration" do
    test "an external execute decided when it is asked, taking the run's id" do
      [tool] = Opus.Provider.tools()
      retry = Enum.find(tool.operations, &(&1.action == "retry"))

      assert {retry.kind, retry.planes, retry.permission, retry.standing} ==
               {:execute, [:external], :execute, false}

      assert [%Prima.Arg{name: "execution_id", required: true}] = retry.args
    end
  end

  describe "a retry" do
    test "runs a scheduled run that failed again with its component, input and grant", %{
      ctx: ctx
    } do
      failed = scheduled_failure!(ctx)
      script!([%{"answer" => "sunny"}])
      watch_runs(ctx)

      assert {:ok, %{status: "accepted", execution_id: again, retry_of: ^failed} = answer} =
               retry(ctx, failed)

      assert Map.keys(answer) |> Enum.sort() == [:execution_id, :retry_of, :status]
      refute again == failed
      assert_receive %Cyfr.Bus.Execution{execution_id: ^again, kind: :completed}, 10_000

      {:ok, original} = Record.get(ctx, failed)
      {:ok, rerun} = Record.get(ctx, again)

      assert %Record{
               status: :completed,
               reference: @pinned,
               parent_execution_id: nil,
               kind: "component",
               profile_id: @profile_id,
               schedule_id: nil
             } = rerun

      assert rerun.component_digest == original.component_digest
      assert {:ok, @consent} = Arca.Execution.root_consent(Sanctum.Context.actor(ctx), again)
      assert origin(again) == "interactive"
      assert origin(failed) == "schedule"
      assert {:ok, @input} = Record.input(ctx, original)
      assert {:ok, @input} = Record.input(ctx, rerun)

      # The failed run stands as it was; a retry is a run of its own.
      assert %Record{status: :failed, error_class: :internal} = original
    end

    test "answers accepted for a rerun that fails again, its failure the run's own event", %{
      ctx: ctx
    } do
      failed = scheduled_failure!(ctx)
      script!([{:error, "still gone"}])
      watch_runs(ctx)

      # The press is answered for the run that started; the run's failure
      # is the run's, never a refusal of the retry.
      assert {:ok, %{status: "accepted", execution_id: again, retry_of: ^failed}} =
               retry(ctx, failed)

      refute again == failed

      assert_receive %Cyfr.Bus.Execution{execution_id: ^again, kind: :failed, error: error},
                     10_000

      assert %{class: :internal} = error
      assert {:ok, %Record{status: :failed, schedule_id: nil}} = Record.get(ctx, again)
    end

    test "answers once the rerun starts, without waiting for it, and the rerun outlives the caller",
         %{ctx: ctx} do
      failed = scheduled_failure!(ctx)
      # The rerun holds at the probe until this test lets it go.
      script!([{:probe, self()}, %{"answer" => "late"}])
      watch_runs(ctx)

      press = Task.async(fn -> retry(ctx, failed) end)
      assert_receive {:scripted_probe, runner, again}, 10_000

      assert {:ok, {:ok, %{status: "accepted", execution_id: ^again, retry_of: ^failed}}} =
               Task.yield(press, 2_000),
             "the retry waited for the rerun to end"

      # The caller has gone; the rerun goes on and ends as a run does.
      refute Process.alive?(press.pid)
      assert {:ok, %Record{status: :running}} = Record.get(ctx, again)
      send(runner, :continue)
      assert_receive %Cyfr.Bus.Execution{execution_id: ^again, kind: :completed}, 10_000
    end

    test "refuses another athanor's run as one that does not exist, and runs nothing", %{
      ctx: ctx
    } do
      failed = scheduled_failure!(ctx)
      before = rows(ctx)

      stranger = %{ctx | athanor_id: "ath_retry_foreign", user_id: "local|local|retry-stranger"}
      assert refused(retry(stranger, failed)) == {:not_found, "Execution not found: #{failed}"}

      assert refused(retry(ctx, "exec_nobody")) ==
               {:not_found, "Execution not found: exec_nobody"}

      assert rows(ctx) == before
    end

    test "refuses a run that did not fail", %{ctx: ctx} do
      script!([%{"answer" => "sunny"}])
      {{:ok, %{metadata: %{execution_id: completed}}}, _schedule} = scheduled(ctx)
      before = rows(ctx)

      assert refused(retry(ctx, completed)) == {:conflict, "Only a failed run can be retried."}
      assert rows(ctx) == before
    end

    test "refuses a failed run a schedule or a feed did not start", %{ctx: ctx} do
      script!([{:error, "upstream gone"}])
      id = Prima.UUID7.execution_id()

      {:error, _} =
        Opus.run_root(ctx, {:id, @profile_id}, @pinned, @input, execution_id: id)

      assert {:ok, %Record{status: :failed, schedule_id: nil}} = Record.get(ctx, id)
      before = rows(ctx)

      assert refused(retry(ctx, id)) ==
               {:conflict, "Only a run a schedule or a feed started can be retried."}

      assert rows(ctx) == before
    end

    test "refuses a run whose grant has a new revision since it ran, and runs nothing", %{
      ctx: ctx,
      digest: digest
    } do
      failed = scheduled_failure!(ctx)
      consented!(ctx, digest, @consent <> "-r2")
      before = rows(ctx)

      assert {:conflict, sentence} = refused(retry(ctx, failed))
      assert sentence =~ "The grant this run ran under has changed since"
      assert rows(ctx) == before
    end

    test "refuses a run whose profile no longer stands", %{ctx: ctx, digest: digest} do
      failed = scheduled_failure!(ctx)
      consented!(ctx, digest, @consent, :revoked)
      before = rows(ctx)

      assert {:conflict, sentence} = refused(retry(ctx, failed))
      assert sentence =~ "The grant this run ran under has changed since"
      assert rows(ctx) == before
    end

    test "refuses a scheduled run whose outcome is uncertain", %{ctx: ctx} do
      # The run's attempt lapses while it runs: the row fails, but what the
      # run did before is not known, so it is never run again.
      script!([{:probe, self()}, :hang])
      id = Prima.UUID7.execution_id()
      task = Task.async(fn -> scheduled(ctx, id) end)
      assert_receive {:scripted_probe, _runner, ^id}, 10_000

      attempt =
        Arca.Repo.one!(
          from(a in Arca.Schemas.ExecutionAttempt,
            where: a.execution_id == ^id and a.athanor_id == ^ctx.athanor_id
          )
        )

      assert {:ok, [_]} = Opus.Lapse.boot(attempt.service_id, attempt.boot_id, [attempt.attempt])

      assert :ok =
               Opus.Attempt.stop_unclosed(attempt.attempt, %{
                 service_id: attempt.service_id,
                 boot_id: attempt.boot_id,
                 runner: nil
               })

      assert {{:error, {:uncertain, _}}, _schedule} = Task.await(task, 10_000)
      assert {:ok, %Record{status: :failed, error_class: :uncertain}} = Record.get(ctx, id)
      before = rows(ctx)
      script!([%{"answer" => "sunny"}])

      assert refused(retry(ctx, id)) ==
               {:conflict,
                "This run's outcome is uncertain: it is not known to have failed, so it is not " <>
                  "run again."}

      assert rows(ctx) == before
    end

    test "refuses a scheduled run its runtime stopped at its time budget", %{
      ctx: ctx,
      digest: digest
    } do
      # Consented two seconds, the run never answers: the worker service
      # stops it at its budget with its native work possibly still running,
      # so what it did is not known and it is never run again.
      consented!(ctx, digest, @consent <> "-short", :active, %{"timeout" => "2s"})
      script!([:hang])
      id = Prima.UUID7.execution_id()

      assert {{:error, {:uncertain, "Execution timeout after " <> _}}, _schedule} =
               scheduled(ctx, id)

      assert {:ok,
              %Record{
                status: :failed,
                error_class: :uncertain,
                error: "Execution timeout after " <> _
              }} = Record.get(ctx, id)

      before = rows(ctx)
      script!([%{"answer" => "sunny"}])

      assert refused(retry(ctx, id)) ==
               {:conflict,
                "This run's outcome is uncertain: it is not known to have failed, so it is not " <>
                  "run again."}

      assert rows(ctx) == before
    end

    test "refuses a failed run whose attempt did not close in the run's own failure", %{
      ctx: ctx
    } do
      failed = scheduled_failure!(ctx)

      # The one outcome a retry reads as failed is the run's own `error`;
      # a lost result is not known to have failed.
      {1, _} =
        Arca.Repo.update_all(
          from(a in Arca.Schemas.ExecutionAttempt, where: a.execution_id == ^failed),
          set: [outcome: "result_lost"]
        )

      before = rows(ctx)
      assert {:conflict, sentence} = refused(retry(ctx, failed))
      assert sentence =~ "outcome is uncertain"
      assert rows(ctx) == before
    end

    test "refuses a run whose input is no longer kept", %{ctx: ctx} do
      failed = scheduled_failure!(ctx)

      {count, _} =
        Arca.Repo.delete_all(
          from(p in "execution_payloads", where: p.execution_id == ^failed and p.kind == "input")
        )

      assert count == 1
      before = rows(ctx)

      assert refused(retry(ctx, failed)) ==
               {:unavailable, "The payload this needs is no longer retained"}

      assert rows(ctx) == before
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp retry(ctx, id),
    do: Sanctum.Gate.call_external("execution", ctx, %{"action" => "retry", "execution_id" => id})

  # The athanor's run lifecycle as `runs.changes` reads it.
  defp watch_runs(ctx) do
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.executions(actor))
  end

  defp refused({:error, reason}) do
    %Prima.Refusal{class: class, message: message} = Sanctum.Refusals.classify(reason)
    {class, message}
  end

  # A run as the scheduler starts one (`Opus.Schedules.Scheduler`): an
  # occurrence of a due schedule claimed, then the run under the schedule
  # origin, the schedule's profile and its retention class, running that
  # occurrence.
  defp scheduled(ctx, id \\ Prima.UUID7.execution_id()) do
    actor = Sanctum.Context.actor(ctx)

    {:ok, schedule} =
      CronSchedule.create(actor, %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "retried-#{System.unique_integer([:positive])}",
        cron_expression: hourly_away(),
        reference: @reference,
        resolved_reference: @pinned,
        profile_id: @profile_id,
        next_run_at: DateTime.add(DateTime.utc_now(), -5, :second),
        cap: 1_000
      })

    {:ok, row} = CronSchedule.get_for_daemon(schedule.id)
    {:ok, parsed} = Cron.parse(row.cron_expression)

    cadence = %{
      next_after: &Cron.next_run(parsed, &1),
      missed_bound_ms: Scheduler.missed_bound_ms()
    }

    {:ok, occurrence} = ScheduleOccurrences.claim(row, Prima.Boot.id(), cadence)

    result =
      Opus.run_root(%{ctx | origin: :schedule}, {:id, @profile_id}, @pinned, @input,
        execution_id: id,
        occurrence_id: occurrence.id,
        schedule_id: schedule.id,
        retention_class: "schedule"
      )

    {result, schedule.id}
  end

  defp scheduled_failure!(ctx) do
    script!([{:error, "upstream gone"}])
    id = Prima.UUID7.execution_id()
    {{:error, _}, schedule_id} = scheduled(ctx, id)
    assert {:ok, %Record{status: :failed, schedule_id: ^schedule_id}} = Record.get(ctx, id)
    id
  end

  defp origin(id) do
    Arca.Repo.one(from(e in "executions", where: e.id == ^id, select: e.origin))
  end

  # The athanor's execution rows, by id.
  defp rows(ctx) do
    Arca.Repo.all(
      from(e in "executions",
        where: e.athanor_id == ^ctx.athanor_id,
        select: e.id,
        order_by: e.id
      )
    )
  end

  defp script!(items) do
    if Process.whereis(ScriptedWorker),
      do: ScriptedWorker.script(items),
      else: start_supervised!({ScriptedWorker, ref: @reference, script: items})
  end

  defp published!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: "retried",
        version: "1.0.0",
        type: "catalyst"
      })

    component.release_digest
  end

  defp consented!(ctx, release_digest, consent_id, status \\ :active, limits \\ %{}) do
    profile = %{
      id: @profile_id,
      kind: :owner,
      source_ref: @reference,
      label: "default",
      status: status
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: consent_id,
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{consent_id}",
        commit_digest: "sha256:commit-#{consent_id}",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @reference => %{
                "limits" => AuthorityFixtures.limits_map(limits),
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@reference => release_digest},
        admitted_origins: [:interactive, :schedule],
        vault_refs: []
      })
  end
end
