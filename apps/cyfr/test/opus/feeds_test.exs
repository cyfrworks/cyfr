# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FeedsTest do
  @moduledoc """
  A feed's engine: a feed fires through the scheduler as a schedule does,
  from its first occurrence on, under a seq it claims at fire. Its result
  is the data of the run's 2xx envelope, kept only when it is JSON, within
  its bound and shape, claimed after the result it replaces, and written
  by a member that still owns its slot; any other output is refused as an
  error named only by its status. A feed's writes are held to its athanor,
  and a feed announces no schedule completion and no schedule update. A
  fire publishes an accepted result on the athanor's feeds topic once its
  accept committed, and a refused, stale or fenced-off result publishes
  nothing.

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
  alias Opus.Feeds
  alias Opus.Schedules.{Provider, Scheduler}
  alias Cyfr.Bus.{FeedPublished, ScheduleCompleted}
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "catalyst:local.markets"
  @pinned "catalyst:local.markets:1.0.0"
  @profile_id "prof_feeds"
  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @vectors_path Path.expand("../../../../tests/fixtures/feed.json", __DIR__)
  @external_resource @vectors_path

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "feeds_#{System.unique_integer([:positive])}")
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
    consented!(ctx)
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  describe "a fire" do
    test "runs through the scheduler at once, claims its seq, and keeps an accepted result",
         %{ctx: ctx, actor: actor} do
      script!([%{"price" => 42.5}, %{"price" => 42.5}])
      watch_outcomes(actor)
      scheduler!()

      binding = feed_binding("btc")
      {:ok, feed} = bind(actor, binding)
      Scheduler.add(feed.id)

      # A schedule beside it fires exactly as before: its completion and
      # its schedule updates are still announced.
      schedule = create_schedule(ctx, "btc")
      Scheduler.add(schedule.id)

      wait_until(fn -> match?([%{state: "completed"}], occurrences(actor, feed.id)) end)
      wait_until(fn -> match?([%{state: "completed"}], occurrences(actor, schedule.id)) end)

      assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 1, run_count: 1} = row} =
               CronSchedule.get_feed(actor, feed.id)

      # The result is the data of the run's 2xx envelope.
      assert {:ok, %{"price" => 42.5}} == Prima.Json.decode(row.feed_result)
      assert %DateTime{} = row.feed_result_at
      # The claim moved the cursor along the feed's cron.
      assert DateTime.compare(row.next_run_at, feed.next_run_at) == :gt

      assert {:ok, %{binding_id: id, feed_result_seq: 1, result: %{"price" => 42.5}}} =
               Feeds.get(ctx, feed.id)

      assert id == feed.id

      # The run is the binding's operation and arguments, under its pinned
      # version, as a scheduled fire.
      assert Enum.any?(ScriptedWorker.calls(), &(&1.input == Prima.Feed.input(binding)))
      [%{execution_id: execution_id}] = occurrences(actor, feed.id)

      assert [%{schedule_id: schedule_id}] =
               Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.id == ^execution_id))

      assert schedule_id == feed.id

      assert_receive %ScheduleCompleted{schedule_id: completed}, 10_000
      assert completed == schedule.id
      assert_receive %Cyfr.Bus.Schedules{schedule_id: updated}, 10_000
      assert updated == schedule.id
      assert_receive {:schedule_outcome, [:cyfr, :schedules, :completed], %{schedule_id: _}}

      refute_receive %ScheduleCompleted{schedule_id: ^id}, 300
      refute_received %Cyfr.Bus.Schedules{schedule_id: ^id}
    end

    test "a refused result is recorded as the occurrence's error, never by its content",
         %{actor: actor} do
      script!([%{"price" => "a secret quote"}])
      watch_outcomes(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))

      log =
        capture_log(fn ->
          scheduler!()
          wait_until(fn -> match?([%{state: "failed"}], occurrences(actor, feed.id)) end)

          wait_until(fn ->
            match?({:ok, %{error_count: 1}}, CronSchedule.get_feed(actor, feed.id))
          end)
        end)

      assert {:ok,
              %{
                feed_fire_seq: 1,
                feed_result_seq: 0,
                feed_result: nil,
                run_count: 0,
                error_count: 1
              }} = CronSchedule.get_feed(actor, feed.id)

      assert_receive {:schedule_outcome, [:cyfr, :schedules, :failed], %{reason: reason}}, 10_000
      assert {:invalid_argument, sentence} = reason
      assert sentence =~ ~s(type at "/price")
      refute inspect(reason) =~ "a secret quote"

      assert log =~ ~s(type at "/price")
      refute log =~ "a secret quote"
    end

    test "an error envelope fails its run, as any component's error does, and writes no result",
         %{actor: actor} do
      # A fire runs with a schedule's options, so the execution layer
      # (`Opus.Close`) fails a run whose output holds `error` before the
      # feed's acceptance sees it: the run's failure is the occurrence's.
      script!([{:refuse, %{"type" => "rate_limited", "message" => "slow down"}}])
      watch_outcomes(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))

      capture_log(fn ->
        scheduler!()
        wait_until(fn -> match?([%{state: "failed"}], occurrences(actor, feed.id)) end)

        wait_until(fn ->
          match?({:ok, %{error_count: 1}}, CronSchedule.get_feed(actor, feed.id))
        end)
      end)

      assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 0, feed_result: nil, run_count: 0}} =
               CronSchedule.get_feed(actor, feed.id)

      [%{execution_id: execution_id}] = occurrences(actor, feed.id)

      assert [%{status: "failed"}] =
               Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.id == ^execution_id))

      assert_receive {:schedule_outcome, [:cyfr, :schedules, :failed], %{reason: reason}}, 10_000
      refute match?({:invalid_argument, "feed result refused" <> _}, reason)
    end

    # The `"error"` reason is named by its sentence, never by its code.
    for {label, output, named} <- [
          {"a non-2xx data envelope", %{"status" => 503, "data" => %{"price" => "a secret"}},
           "the operation answered an error, or no envelope (status 503)"},
          {"an envelope with a key besides status and data",
           %{"status" => 200, "data" => %{"price" => 1}, "note" => "a secret"},
           "the operation answered an error, or no envelope (status 200)"},
          {"an output that is no envelope", %{"price" => 1, "note" => "a secret"},
           "the operation answered an error, or no envelope"}
        ] do
      test "#{label} completes its run and is refused as the occurrence's error, by status only",
           %{actor: actor} do
        script!([{:output, unquote(Macro.escape(output))}])
        watch_outcomes(actor)
        {:ok, feed} = bind(actor, feed_binding("btc"))

        log =
          capture_log(fn ->
            scheduler!()
            wait_until(fn -> match?([%{state: "failed"}], occurrences(actor, feed.id)) end)

            wait_until(fn ->
              match?({:ok, %{error_count: 1}}, CronSchedule.get_feed(actor, feed.id))
            end)
          end)

        assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 0, feed_result: nil, run_count: 0}} =
                 CronSchedule.get_feed(actor, feed.id)

        # The run itself completed: the refusal is the feed's.
        [%{execution_id: execution_id}] = occurrences(actor, feed.id)

        assert [%{status: "completed"}] =
                 Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.id == ^execution_id))

        assert_receive {:schedule_outcome, [:cyfr, :schedules, :failed], %{reason: reason}},
                       10_000

        assert {:invalid_argument, "feed result refused: " <> named} = reason
        assert named == unquote(named)
        refute inspect(reason) =~ "a secret"

        assert log =~ "feed result refused: " <> unquote(named)
        refute log =~ "a secret"
      end
    end

    test "an earlier-started result never replaces a later one", %{ctx: ctx, actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()

      # The fire has claimed its seq and its run is in flight.
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 0}} =
               CronSchedule.get_feed(actor, feed.id)

      # A refresh starts after it, claims the next seq and finishes first.
      {:ok, slot} = Arca.ControlPlane.member_slot()
      assert {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:ok, %{"revision" => 2}} = Feeds.accept(ctx, feed.id, 2, answer(2.0), slot)

      task = running_task()
      ref = Process.monitor(task)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      _ = :sys.get_state(scheduler)

      # The fire's result was stale: its occurrence completed and its run
      # is recorded, and the refresh's result stands.
      assert [%{state: "completed"}] = occurrences(actor, feed.id)

      assert {:ok, %{feed_result_seq: 2, run_count: 1, error_count: 0} = row} =
               CronSchedule.get_feed(actor, feed.id)

      assert {:ok, %{"price" => 2.0}} == Prima.Json.decode(row.feed_result)
    end

    test "an older fire's invalid result is stale, so its occurrence completes and records no error",
         %{ctx: ctx, actor: actor} do
      script!([{:probe, self()}, %{"price" => "not a number"}])
      watch_outcomes(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # A refresh claims the next seq and is accepted while the fire runs.
      {:ok, slot} = Arca.ControlPlane.member_slot()
      assert {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:ok, %{"revision" => 2}} = Feeds.accept(ctx, feed.id, 2, answer(2.0), slot)

      task = running_task()
      ref = Process.monitor(task)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      _ = :sys.get_state(scheduler)

      # The fire's output would be refused for its shape, but its seq is
      # stale first: the occurrence completes, the run is recorded, no
      # error is.
      assert [%{state: "completed"}] = occurrences(actor, feed.id)

      assert {:ok, %{feed_result_seq: 2, run_count: 1, error_count: 0} = row} =
               CronSchedule.get_feed(actor, feed.id)

      assert {:ok, %{"price" => 2.0}} == Prima.Json.decode(row.feed_result)
      assert_received {:schedule_outcome, [:cyfr, :schedules, :completed], _}
      refute_received {:schedule_outcome, [:cyfr, :schedules, :failed], _}
    end

    test "a fire whose member lost its slot during the run writes nothing for its invalid result",
         %{actor: actor} do
      slot = claimant!()
      script!([{:probe, self()}, %{"price" => "not a number"}])
      watch_outcomes(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000
      assert {:ok, %{feed_fire_seq: 1}} = CronSchedule.get_feed(actor, feed.id)

      # A successor takes the slot over while the run is in flight; this
      # member still believes it holds it, so only the acceptance's own
      # check stands between it and the row.
      take_over!(slot)

      task = running_task()
      ref = Process.monitor(task)

      log =
        capture_log(fn ->
          send(worker, :continue)
          assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
          _ = :sys.get_state(scheduler)
        end)

      # The output would be refused for its shape, but the slot is checked
      # first: nothing is written, and the occurrence is left to recovery.
      assert log =~ "no longer owns its slot"
      assert [%{state: "started"}] = occurrences(actor, feed.id)

      assert {:ok, %{feed_result_seq: 0, feed_result: nil, run_count: 0, error_count: 0}} =
               CronSchedule.get_feed(actor, feed.id)

      refute_received {:schedule_outcome, _, _}
    end

    test "a member that lost its slot claims no feed's occurrence: it defers, writing nothing",
         %{actor: actor} do
      slot = claimant!()
      script!([%{"price" => 1.0}])
      watch_outcomes(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))

      # A successor takes the slot over before the first fire; this
      # member's cached standing still says it holds it, so the scheduler
      # fires, and only the claim's own check stands between it and the row.
      take_over!(slot)
      assert Arca.ControlPlane.held?()

      scheduler = scheduler!()

      # The fire was answered `:not_owner` and deferred, as a lost
      # generation defers: the occurrence is looked at again later, its
      # timer a recheck a tick or more away rather than the fire it was
      # loaded with, and the deferral's own pass, a tick away, fires before
      # the one the scheduler's start asked for two ticks away.
      wait_until(fn ->
        timer = :sys.get_state(scheduler).timers[feed.id]
        is_reference(timer) and (Process.read_timer(timer) || 0) > 15_000
      end)

      state = :sys.get_state(scheduler)
      assert Process.read_timer(state.recovery_ref) <= 30_000

      assert occurrences(actor, feed.id) == []
      assert {:ok, row} = CronSchedule.get_for_daemon(feed.id)
      assert DateTime.compare(row.next_run_at, feed.next_run_at) == :eq
      assert %{feed_fire_seq: 0, run_count: 0, error_count: 0} = row
      assert ScriptedWorker.calls() == []
      refute_received {:schedule_outcome, _, _}
    end

    test "a feed created and removed before its first claim leaves no occurrence and no run",
         %{actor: actor} do
      script!([%{"price" => 1.0}])
      {:ok, feed} = bind(actor, feed_binding("btc"))
      assert {:ok, _} = CronSchedule.remove_feed(actor, feed.id)

      scheduler = scheduler!()
      Scheduler.remove(feed.id)
      Scheduler.add(feed.id)
      # A timer armed before the removal fires into a removed row.
      send(scheduler, {:fire, feed.id})
      _ = :sys.get_state(scheduler)

      assert occurrences(actor, feed.id) == []

      assert [] =
               Arca.Repo.all(
                 from(o in Arca.Schemas.ScheduleOccurrence, where: o.schedule_id == ^feed.id)
               )

      assert ScriptedWorker.calls() == []
      assert [] = Arca.Repo.all(Arca.Schemas.Execution)
      assert {:ok, %{feed_fire_seq: 0}} = CronSchedule.get_for_daemon(feed.id)
    end
  end

  describe "a fire's publication" do
    test "broadcast only after commit: the event is seen once the row holds the result", %{
      actor: actor
    } do
      script!([%{"price" => 42.5}])
      {:ok, feed} = bind(actor, feed_binding("btc"))
      test = self()

      # A subscriber that reads the row the moment it hears the event.
      spawn_link(fn ->
        :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.feeds(actor))
        send(test, :watching)

        receive do
          %FeedPublished{} = published ->
            {:ok, row} = CronSchedule.get_feed(actor, published.binding)
            send(test, {:heard, published, row})
        end
      end)

      assert_receive :watching
      scheduler!()

      assert_receive {:heard, published, row}, 10_000
      assert published.binding == feed.id
      assert %FeedPublished{feed: "btc", revision: 1, result: %{"price" => 42.5}} = published
      assert %{feed_result_seq: 1} = row
      assert {:ok, %{"price" => 42.5}} == Prima.Json.decode(row.feed_result)

      assert published.at ==
               DateTime.to_iso8601(DateTime.shift_zone!(row.feed_result_at, "Etc/UTC"))

      # The display part of the binding, never its arguments.
      assert published.actions == [%{"name" => "refresh", "label" => "Refresh"}]
      refute inspect(published) =~ "BTC"
    end

    test "a refused result publishes nothing", %{actor: actor} do
      script!([%{"price" => "not a number"}])
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))

      capture_log(fn ->
        scheduler!()
        wait_until(fn -> match?([%{state: "failed"}], occurrences(actor, feed.id)) end)
      end)

      # A publish is sent before the occurrence ends, so none was.
      refute_received %FeedPublished{}
    end

    test "a stale result publishes nothing", %{ctx: ctx, actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # A later claim's result is accepted while the fire runs; accepting
      # alone publishes nothing, the press or fire that accepted does.
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)
      {:ok, _envelope} = Feeds.accept(ctx, feed.id, 2, answer(2.0), slot)

      task = running_task()
      ref = Process.monitor(task)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      _ = :sys.get_state(scheduler)

      assert [%{state: "completed"}] = occurrences(actor, feed.id)
      refute_received %FeedPublished{}
    end

    test "a stale member's accepted-looking result publishes nothing", %{actor: actor} do
      slot = claimant!()
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # Taken over while the run is in flight: the result is valid, and
      # only the acceptance's own fence refuses it.
      take_over!(slot)
      task = running_task()
      ref = Process.monitor(task)

      capture_log(fn ->
        send(worker, :continue)
        assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
        _ = :sys.get_state(scheduler)
      end)

      assert {:ok, %{feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, feed.id)

      refute_received %FeedPublished{}
    end
  end

  describe "a fire's other ends" do
    test "an accept answered :not_found, the feed removed during the run, completes and records no error",
         %{actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_outcomes(actor)
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      assert {:ok, _removed} = CronSchedule.remove_feed(actor, feed.id)

      task = running_task()
      ref = Process.monitor(task)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
      _ = :sys.get_state(scheduler)

      assert [%{state: "completed"}] = occurrences(actor, feed.id)

      assert {:ok, %{status: "deleted", feed_result_seq: 0, feed_result: nil, error_count: 0}} =
               CronSchedule.get_for_daemon(feed.id)

      assert_received {:schedule_outcome, [:cyfr, :schedules, :completed], %{schedule_id: id}}
      assert id == feed.id
      refute_received {:schedule_outcome, [:cyfr, :schedules, :failed], _}
      refute_received %FeedPublished{}
    end

    test "an accept the store refuses otherwise (:unclaimed) fails the occurrence and records it",
         %{actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_outcomes(actor)
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))
      scheduler = scheduler!()
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # The claimed seq no longer reads as claimed when the run answers.
      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^feed.id),
          set: [feed_fire_seq: 0]
        )

      task = running_task()
      ref = Process.monitor(task)

      capture_log(fn ->
        send(worker, :continue)
        assert_receive {:DOWN, ^ref, :process, ^task, _}, 10_000
        _ = :sys.get_state(scheduler)
      end)

      assert [%{state: "failed"}] = occurrences(actor, feed.id)

      assert {:ok, %{feed_result_seq: 0, feed_result: nil, run_count: 0, error_count: 1}} =
               CronSchedule.get_feed(actor, feed.id)

      assert_received {:schedule_outcome, [:cyfr, :schedules, :failed], %{reason: :unclaimed}}
      refute_received %FeedPublished{}
    end

    test "a seq claim refused :not_found, the feed removed after its occurrence was claimed, fails it",
         %{actor: actor} do
      script!([%{"price" => 1.0}])
      watch_outcomes(actor)
      watch_feeds(actor)
      {:ok, feed} = bind(actor, feed_binding("btc"))

      # Loaded with its first occurrence an hour away, so the scheduler
      # starts idle.
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^feed.id),
          set: [next_run_at: later]
        )

      scheduler = scheduler!()
      _ = :sys.get_state(scheduler)

      # The run's task cannot start while the task supervisor is held: the
      # fire claims its occurrence and waits there, and the feed is removed
      # before its task claims a seq.
      tasks = Process.whereis(Opus.Schedules.TaskSupervisor)
      :ok = :sys.suspend(tasks)
      on_exit(fn -> if Process.alive?(tasks), do: :sys.resume(tasks) end)

      due = DateTime.add(DateTime.utc_now(), -5, :second)

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^feed.id),
          set: [next_run_at: due]
        )

      send(scheduler, {:fire, feed.id})
      wait_until(fn -> match?([%{state: "claimed"}], occurrences(actor, feed.id)) end)
      assert {:ok, _removed} = CronSchedule.remove_feed(actor, feed.id)

      capture_log(fn ->
        :ok = :sys.resume(tasks)
        wait_until(fn -> match?([%{state: "failed"}], occurrences(actor, feed.id)) end)

        wait_until(fn ->
          match?({:ok, %{error_count: 1}}, CronSchedule.get_for_daemon(feed.id))
        end)
      end)

      assert [%{state: "failed", execution_id: nil}] = occurrences(actor, feed.id)

      assert {:ok, %{status: "deleted", feed_fire_seq: 0, run_count: 0, error_count: 1}} =
               CronSchedule.get_for_daemon(feed.id)

      assert ScriptedWorker.calls() == []
      assert_received {:schedule_outcome, [:cyfr, :schedules, :failed], %{reason: :not_found}}
      refute_received %FeedPublished{}
    end
  end

  describe "accept/5" do
    test "an accepted result answers the envelope of the row it wrote, never the arguments", %{
      ctx: ctx,
      actor: actor
    } do
      binding = feed_binding("btc")
      {:ok, feed} = bind(actor, binding)
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)

      assert {:ok, envelope} = Feeds.accept(ctx, feed.id, seq, answer(5), slot)
      {:ok, row} = CronSchedule.get_feed(actor, feed.id)

      assert envelope ==
               Prima.Feed.envelope(
                 feed.id,
                 binding,
                 row.feed_result_seq,
                 row.feed_result_at,
                 %{"price" => 5}
               )

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(actions at binding feed label result revision)

      refute inspect(envelope) =~ "BTC"
    end

    test "a result outside its shape changes nothing", %{ctx: ctx, actor: actor} do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)
      # The bound is the data's, not the envelope's.
      pad = String.duplicate("x", Prima.Feed.result_max_bytes())
      oversized = envelope(%{"price" => 1, "pad" => pad})

      for {output, refusal} <- [
            {~s({"status":200,"data":{"price":"high"}}), %{path: "/price", reason: "type"}},
            {envelope(%{"price" => 1, "extra" => true}),
             %{path: "/extra", reason: "unknown_field"}},
            {envelope(%{}), %{path: "/price", reason: "required"}},
            {"not json", %{path: "", reason: "json"}},
            {42, %{path: "", reason: "json"}},
            {answer({1, 2}), %{path: "", reason: "json"}},
            {oversized, %{path: "", reason: "size"}}
          ] do
        assert {:error, {:refused, ^refusal}} = Feeds.accept(ctx, feed.id, seq, output, slot)
      end

      assert {:ok, %{feed_result_seq: 0, feed_result: nil, feed_result_at: nil}} =
               CronSchedule.get_feed(actor, feed.id)

      # A seq nobody claimed is refused as it is, and writes nothing.
      assert {:error, :unclaimed} = Feeds.accept(ctx, feed.id, seq + 1, answer(1), slot)

      # JSON text and a decoded value are the same output, and the result
      # is its envelope's data.
      assert {:ok, %{"revision" => ^seq, "result" => %{"price" => 3}}} =
               Feeds.accept(ctx, feed.id, seq, ~s({"status":201,"data":{"price":3}}), slot)

      assert {:ok, %{result: %{"price" => 3}, feed_result_seq: ^seq}} = Feeds.get(ctx, feed.id)
      assert {:error, :stale} = Feeds.accept(ctx, feed.id, seq, answer(4), slot)
    end

    test "an output that is not a 2xx envelope is refused as an error, named only by its status",
         %{ctx: ctx, actor: actor} do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)
      error = %{"type" => "rate_limited", "message" => "a secret refusal"}

      for {output, refusal} <- [
            # A status outside 2xx, with data or with an error.
            {%{"status" => 503, "data" => %{"price" => 1}}, error_refusal(503)},
            {%{"status" => 199, "data" => %{"price" => 1}}, error_refusal(199)},
            {%{"status" => 300, "data" => %{"price" => 1}}, error_refusal(300)},
            {%{"status" => 429, "error" => error}, error_refusal(429)},
            # An error envelope, whatever its status, or with none.
            {%{"error" => error}, error_refusal()},
            {%{"status" => 200, "error" => error}, error_refusal(200)},
            # An envelope with a key besides `status` and `data`.
            {Map.put(answer(1), "note", "a secret note"), error_refusal(200)},
            {Map.put(answer(1), "error", error), error_refusal(200)},
            # No envelope at all: the data alone, a scalar, a list, a
            # status that is not an integer, or one with no data.
            {%{"price" => 1}, error_refusal()},
            {~s("a secret string"), error_refusal()},
            {~s(42), error_refusal()},
            {[answer(1)], error_refusal()},
            {%{"status" => "200", "data" => %{"price" => 1}}, error_refusal()},
            {%{"status" => 200.0, "data" => %{"price" => 1}}, error_refusal()},
            {%{"status" => 200}, error_refusal(200)},
            {%{}, error_refusal()}
          ] do
        assert {:error, {:refused, ^refusal}} = Feeds.accept(ctx, feed.id, seq, output, slot),
               "#{inspect(output)} was not refused as #{inspect(refusal)}"
      end

      assert {:ok, %{feed_result_seq: 0, feed_result: nil, feed_result_at: nil}} =
               CronSchedule.get_feed(actor, feed.id)

      # 200 and 299 bound the range.
      assert {:ok, _envelope} =
               Feeds.accept(ctx, feed.id, seq, envelope(%{"price" => 2}, 299), slot)

      assert {:ok, %{result: %{"price" => 2}}} = Feeds.get(ctx, feed.id)
    end

    test "a stale member writes no result", %{ctx: ctx, actor: actor} do
      # The slot the claim was made under, which the acceptance is fenced by.
      slot = claimant!()
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)

      take_over!(slot)

      assert {:error, :not_owner} = Feeds.accept(ctx, feed.id, seq, answer(1), slot)

      assert {:ok, %{feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, feed.id)
    end

    test "the slot is checked first: a stale member's invalid result is :not_owner", %{
      ctx: ctx,
      actor: actor
    } do
      slot = claimant!()
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)
      take_over!(slot)

      for output <- invalid_outputs() do
        assert {:error, :not_owner} = Feeds.accept(ctx, feed.id, seq, output, slot),
               "#{inspect(output)} was not answered :not_owner"
      end

      assert {:ok, %{feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, feed.id)
    end

    test "the seq is checked before the result: an older invalid result is :stale", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)
      {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)
      {:ok, _envelope} = Feeds.accept(ctx, feed.id, 2, answer(2), slot)

      for output <- invalid_outputs(), seq <- [1, 2] do
        assert {:error, :stale} = Feeds.accept(ctx, feed.id, seq, output, slot),
               "#{inspect(output)} at seq #{seq} was not answered :stale"
      end

      # And an unclaimed seq is answered as one, whatever it carries.
      assert {:error, :unclaimed} = Feeds.accept(ctx, feed.id, 3, "not json", slot)

      assert {:ok, %{result: %{"price" => 2}, feed_result_seq: 2}} = Feeds.get(ctx, feed.id)
    end
  end

  describe "the cap" do
    test "the schedule cap counts schedules only", %{ctx: ctx, actor: actor} do
      Cyfr.Test.Settings.put("max_schedules_per_athanor", 3)
      for i <- 1..2, do: {:ok, _} = bind(actor, feed_binding("feed-#{i}"), 2)

      for i <- 1..3 do
        assert {:ok, _} = Provider.handle("schedule", ctx, schedule_args("cap-#{i}"))
      end

      assert {:error, "Schedule limit reached (3 per athanor)"} =
               Provider.handle("schedule", ctx, schedule_args("cap-4"))

      # And the feeds' bound counts feeds only, beside three schedules.
      assert {:error, :feed_cap} = bind(actor, feed_binding("feed-3"), 2)
      assert {:ok, 3} = Arca.Test.CronSlots.occupied(actor, "schedule")
      assert {:ok, 2} = Arca.Test.CronSlots.occupied(actor, "feed")
    end
  end

  describe "a member that lost its slot after admission" do
    setup do
      {:ok, slot: claimant!()}
    end

    test "create refuses a member that lost its slot after admission", %{actor: actor, slot: slot} do
      take_over!(slot)
      assert Arca.ControlPlane.held?()

      assert {:error, :not_owner} = bind(actor, feed_binding("btc"))
      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "a seq claim refuses a member that lost its slot after admission", %{
      actor: actor,
      slot: slot
    } do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      take_over!(slot)

      assert {:error, :not_owner} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:ok, %{feed_fire_seq: 0}} = CronSchedule.get_feed(actor, feed.id)
    end

    test "removal refuses a member that lost its slot after admission", %{
      actor: actor,
      slot: slot
    } do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      take_over!(slot)

      assert {:error, :not_owner} = CronSchedule.remove_feed(actor, feed.id)
      assert {:ok, %{status: "active"}} = CronSchedule.get_feed(actor, feed.id)
    end
  end

  describe "another athanor" do
    test "another athanor's actor reads, claims, accepts and removes nothing by a feed id", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, feed} = bind(actor, feed_binding("btc"))
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)

      foreign_ctx = %{ctx | athanor_id: "ath_other", user_id: "local|local|stranger"}
      foreign = Sanctum.Context.actor(foreign_ctx)

      assert {:ok, []} = Feeds.list(foreign_ctx)
      assert {:error, :not_found} = Feeds.get(foreign_ctx, feed.id)
      assert {:error, :not_found} = CronSchedule.claim_feed_seq(foreign, feed.id)
      assert {:error, :not_found} = Feeds.accept(foreign_ctx, feed.id, 1, answer(1), slot)

      assert {:error, :not_found} =
               CronSchedule.accept_feed_result(foreign, feed.id, 1, ~s({"price":1}), slot)

      assert {:error, :not_found} = CronSchedule.remove_feed(foreign, feed.id)

      assert {:ok, %{status: "active", feed_fire_seq: 1, feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, feed.id)
    end
  end

  describe "the outputs of tests/fixtures/feed.json" do
    test "every row answers as it states, given as JSON text and as the decoded value", %{
      ctx: ctx,
      actor: actor
    } do
      %{"bindings" => %{"valid" => bindings}, "outputs" => %{"binding" => index, "rows" => rows}} =
        @vectors_path |> File.read!() |> Jason.decode!()

      # The section holds what it is said to: an accepted 2xx envelope, and
      # refusals both naming a status and naming none.
      assert Enum.any?(rows, &Map.has_key?(&1, "accepted"))
      assert Enum.any?(rows, &match?(%{"refused" => %{"reason" => "error", "status" => _}}, &1))
      assert Enum.any?(rows, &(&1["refused"] == %{"path" => "", "reason" => "error"}))

      {:ok, binding} = Prima.Feed.Binding.validate(Enum.at(bindings, index)["binding"])
      {:ok, feed} = bind(actor, binding)
      {:ok, slot} = Arca.ControlPlane.member_slot()

      for %{"why" => why, "output" => output} = row <- rows, given <- given_forms(output) do
        {:ok, seq} = CronSchedule.claim_feed_seq(actor, feed.id)
        {:ok, before} = CronSchedule.get_feed(actor, feed.id)
        answer = Feeds.accept(ctx, feed.id, seq, given, slot)

        case row do
          %{"accepted" => data} ->
            assert match?({:ok, %{"revision" => ^seq}}, answer), "#{why}: #{inspect(answer)}"

            assert {:ok, %{feed_result: text, feed_result_seq: ^seq}} =
                     CronSchedule.get_feed(actor, feed.id)

            assert Prima.Json.decode(text) == {:ok, data}, why

          %{"refused" => refused} ->
            assert answer == {:error, {:refused, vector_refusal(refused)}}, why
            assert {:ok, after_refusal} = CronSchedule.get_feed(actor, feed.id)

            assert Map.take(after_refusal, [:feed_result, :feed_result_seq, :feed_result_at]) ==
                     Map.take(before, [:feed_result, :feed_result_seq, :feed_result_at]),
                   why
        end
      end
    end
  end

  describe "the reads" do
    test "list/1 and get/2 answer each live feed by name with its binding and result", %{
      ctx: ctx,
      actor: actor
    } do
      eth = feed_binding("eth")
      {:ok, second} = bind(actor, eth)
      {:ok, first} = bind(actor, feed_binding("btc"))
      {:ok, removed} = bind(actor, feed_binding("gone"))
      {:ok, _} = CronSchedule.remove_feed(actor, removed.id)
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, second.id)
      {:ok, _envelope} = Feeds.accept(ctx, second.id, 1, answer(7), slot)

      assert {:ok,
              [
                %{binding_id: btc_id, feed_result_seq: 0, feed_result_at: nil, result: nil},
                %{
                  binding_id: eth_id,
                  binding: ^eth,
                  feed_result_seq: 1,
                  feed_result_at: %DateTime{},
                  result: %{"price" => 7}
                }
              ]} = Feeds.list(ctx)

      assert {btc_id, eth_id} == {first.id, second.id}
      assert {:ok, %{binding: ^eth}} = Feeds.get(ctx, second.id)
      assert {:error, :not_found} = Feeds.get(ctx, removed.id)
      assert {:ok, ^eth} = Feeds.spec(second)
    end

    test "a row whose stored binding no longer reads is left out, named by its id only", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, kept} = bind(actor, feed_binding("btc"))
      {:ok, broken} = bind(actor, feed_binding("eth"))

      {1, _} =
        Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^broken.id),
          set: [feed_spec: ~s({"name":"eth","secret":"do-not-log"})]
        )

      log =
        capture_log(fn ->
          assert {:ok, [%{binding_id: id}]} = Feeds.list(ctx)
          assert id == kept.id
          assert {:error, :not_found} = Feeds.get(ctx, broken.id)
        end)

      assert log =~ broken.id
      refute log =~ "do-not-log"

      assert {:error, %{path: "/secret", reason: "unknown_key"}} =
               Feeds.spec(%{feed_spec: ~s({"secret":1})})

      assert {:error, %{path: "", reason: "json"}} = Feeds.spec(%{feed_spec: "{"})
      assert {:error, %{path: "", reason: "required"}} = Feeds.spec(%{feed_spec: nil})
    end
  end

  # ---- helpers -----------------------------------------------------------------

  defp consented!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
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
        # The data of the run's 2xx envelope.
        "result_shape" => %{
          "type" => "object",
          "fields" => %{"price" => %{"type" => "number"}},
          "required" => ["price"]
        },
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    binding
  end

  # A run's answer of `price`: the envelope a scripted run completes with.
  defp answer(price), do: envelope(%{"price" => price})

  defp envelope(data, status \\ 200), do: %{"status" => status, "data" => data}

  # A vector row's output as a run hands it over, its JSON text, and an
  # object or a list also as the decoded value `accept/5` takes as it is.
  defp given_forms(output) do
    {:ok, text} = Prima.Json.encode(output)
    if is_map(output) or is_list(output), do: [text, output], else: [text]
  end

  defp vector_refusal(%{"path" => path, "reason" => reason} = refused) do
    case refused do
      %{"status" => status} -> %{path: path, reason: reason, status: status}
      _none -> %{path: path, reason: reason}
    end
  end

  # Outputs each refused for its own bytes when slot and seq hold: not
  # JSON, no 2xx envelope, past the bound, outside the shape.
  defp invalid_outputs do
    pad = String.duplicate("x", Prima.Feed.result_max_bytes())

    [
      "not json",
      %{"status" => 503, "data" => %{"price" => 1}},
      %{"price" => 1},
      envelope(%{"price" => 1, "pad" => pad}),
      envelope(%{"price" => "high"})
    ]
  end

  defp error_refusal, do: %{path: "", reason: "error"}
  defp error_refusal(status), do: %{path: "", reason: "error", status: status}

  defp bind(actor, binding, cap \\ 1_000) do
    CronSchedule.create_feed(actor, %{
      binding: binding,
      resolved_reference: @pinned,
      profile_id: @profile_id,
      cap: cap
    })
  end

  defp create_schedule(ctx, name) do
    {:ok, schedule} =
      CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: name,
        cron_expression: "0 * * * *",
        reference: @pinned,
        resolved_reference: @pinned,
        profile_id: @profile_id,
        next_run_at: DateTime.add(DateTime.utc_now(), -5, :second),
        cap: 1_000
      })

    schedule
  end

  defp schedule_args(name) do
    %{
      "action" => "create",
      "profile_id" => @profile_id,
      "name" => name,
      "cron_expression" => "0 * * * *",
      "reference" => @pinned
    }
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  defp scheduler!, do: start_supervised!(Scheduler)

  defp occurrences(actor, schedule_id) do
    {:ok, rows} = ScheduleOccurrences.list(actor, schedule_id)
    rows
  end

  defp running_task do
    [pid] =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Opus.Schedules.TaskSupervisor),
          is_pid(pid),
          do: pid

    pid
  end

  # The outcomes the scheduler emits, with their metadata, the committed
  # completions on the global topic, and the athanor's schedule updates.
  defp watch_outcomes(actor) do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:cyfr, :schedules, :completed], [:cyfr, :schedules, :failed]],
      fn event, _measurements, metadata, test ->
        send(test, {:schedule_outcome, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_completions())
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.schedules(actor))
  end

  # The athanor's feeds topic, heard by the case itself.
  defp watch_feeds(actor), do: :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.feeds(actor))

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
    node = "node-feeds-#{System.unique_integer([:positive])}"
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

defmodule Opus.FeedsRaceTest do
  @moduledoc """
  Binds racing for an athanor's last feed slots, on connections of their
  own: inside the sandbox one shared connection would serialize them. On
  PostgreSQL every bind is held behind a transaction that locks the
  athanor's row until each is seen waiting on it, so all of them race for
  the row when it is let go; SQLite's one write lock admits one
  transaction at a time, so there they run as concurrent processes. The
  case works in an athanor of its own, whose rows it deletes when it ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.CronSchedule
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @binds 16
  @cap 10

  setup do
    athanor = "ath_feeds_race_#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          from(s in Arca.Schemas.CronSchedule, where: s.athanor_id == ^athanor)
        )

        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
      end)
    end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor)}
  end

  test "concurrent binds stop at the cap", %{actor: actor} do
    cap = @cap
    test = self()

    bind = fn name ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})

          CronSchedule.create_feed(actor, %{
            binding: feed_binding(name),
            resolved_reference: "catalyst:local.markets:1.0.0",
            profile_id: "prof_race",
            cap: cap
          })
        end)
      end)
    end

    answers =
      if postgres?() do
        holder =
          holding(fn ->
            from(a in Arca.Schemas.Athanor, where: a.id == ^actor.athanor_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()
          end)

        binders = for i <- 1..@binds, do: bind.("race-#{i}")

        for _ <- binders do
          assert_receive {:backend, backend}, 15_000
          LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
        end

        release(holder)
        Enum.map(binders, &Task.await(&1, 30_000))
      else
        for(i <- 1..@binds, do: bind.("race-#{i}")) |> Enum.map(&Task.await(&1, 30_000))
      end

    assert Enum.count(answers, &match?({:ok, _}, &1)) == cap
    assert Enum.count(answers, &(&1 == {:error, :feed_cap})) == @binds - cap
    assert {:ok, ^cap} = unboxed(fn -> Arca.Test.CronSlots.occupied(actor, "feed") end)
  end

  defp feed_binding(name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    binding
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            result = lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> result
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    Task.await(task, 30_000)
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end
end
