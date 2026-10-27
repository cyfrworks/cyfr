# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.StreamsTest do
  @moduledoc """
  The schedules' two canvas streams: `schedules.changes` is every live
  schedule first and then each row a committed write left, and
  `schedule_runs.changes` is the newest occurrences of schedules first and
  then each fire and failure. A feed's row and a feed's run reach neither.
  Every refresh item and live payload is checked as a canvas reads it:
  projected, passed through JSON and held to the declared shape.
  """

  # Takes a cell slot through `Arca.ControlPlane`, the process-wide
  # standing record, for the ownership cases, and restores it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Bus.{FeedRun, ScheduleRun, Schedules}
  alias Opus.Schedules.{Changes, Provider}
  alias Prima.Canvas.Shape
  alias Sanctum.Context

  @private_input "PRIVATE-INPUT-7d1c"
  @private_note "PRIVATE-NOTE-41aa"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_sched_streams_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:arca, :base_path)
    on_exit(fn -> Application.put_env(:arca, :base_path, prev_base) end)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: "test",
        version: "1.0.0",
        type: "reagent"
      })

    Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.test",
      profile_id: "prof-cron"
    )

    actor = Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.schedules(actor))
    {:ok, ctx: ctx, actor: actor}
  end

  describe "the declarations" do
    test "the provider declares exactly the two streams, each shaped, subjectless and refreshed" do
      assert Enum.map(Provider.streams(), & &1.name) == [
               "schedules.changes",
               "schedule_runs.changes"
             ]

      for stream <- Provider.streams() do
        assert Prima.Provider.Stream.valid?(stream), stream.name
        assert {stream.subject, stream.filter, stream.bind} == {nil, nil, nil}
        assert stream.deadline_bound == 86_400
        assert {:ok, stream.shape} == Shape.validate(stream.shape)
        assert Enum.sort(Map.keys(stream.shape["fields"])) == Enum.sort(stream.projection)
        assert Enum.sort(stream.shape["required"]) == Enum.sort(stream.projection)
        {module, function} = stream.refresh
        assert function_exported?(module, function, 2)
        assert {:ok, {Provider, ^stream}} = Sanctum.Catalog.lookup_stream(stream.name)
      end

      [schedules, runs] = Provider.streams()
      assert {schedules.topic, runs.topic} == {:schedules, :schedule_runs}

      assert schedules.projection ==
               ~w(kind schedule_id name reference cron_expression status next_run_at last_run_at run_count error_count)

      assert schedules.shape["fields"]["kind"]["values"] == ["changed", "removed"]

      assert runs.projection ==
               ~w(kind schedule_id occurrence_id execution_id scheduled_for reason)

      assert runs.shape["fields"]["kind"]["values"] == ["fired", "failed"]
    end
  end

  describe "a write's announcement" do
    test "create, update, pause, resume and re-resolve each announce the row as it committed",
         %{ctx: ctx} do
      {:ok, %{schedule_id: id}} =
        call(ctx, Map.put(create_args("nightly"), "input", %{"secret" => @private_input}))

      assert %{"kind" => "changed", "name" => "nightly", "status" => "active", "run_count" => 0} =
               heard(id)

      {:ok, _} = call(ctx, %{"action" => "update", "schedule_id" => id, "name" => "nightlier"})
      assert %{"name" => "nightlier"} = heard(id)

      {:ok, _} = call(ctx, %{"action" => "pause", "schedule_id" => id})
      assert %{"status" => "paused", "next_run_at" => _} = heard(id)

      {:ok, _} = call(ctx, %{"action" => "resume", "schedule_id" => id})
      assert %{"status" => "active", "next_run_at" => next} = heard(id)
      assert {:ok, _, 0} = DateTime.from_iso8601(next)

      {:ok, _} = call(ctx, %{"action" => "re_resolve", "schedule_id" => id})
      assert %{"name" => "nightlier", "reference" => "reagent:local.test:1.0.0"} = heard(id)
      refute_receive %Schedules{}, 200
    end

    test "a delete announces removed once, with the row as it was, and nothing after it",
         %{ctx: ctx, actor: actor} do
      {:ok, %{schedule_id: id}} = call(ctx, create_args("to-go"))
      heard(id)
      {:ok, _} = call(ctx, %{"action" => "pause", "schedule_id" => id})
      heard(id)

      {:ok, %{deleted: true}} = call(ctx, %{"action" => "delete", "schedule_id" => id})

      assert_receive %Schedules{kind: :removed, schedule_id: ^id} = removed
      assert %{"kind" => "removed", "status" => "paused", "name" => "to-go"} = read_as(removed)

      # A later announcement of the row, a run's end for one, reads it
      # deleted and says nothing.
      assert :ok = Changes.changed(actor, id)
      refute_receive %Schedules{}, 200
    end

    test "a write the store or the tool refuses announces nothing", %{ctx: ctx} do
      {:ok, %{schedule_id: id}} = call(ctx, create_args("kept"))
      heard(id)

      assert {:error, _} =
               call(ctx, Map.put(create_args("kept"), "cron_expression", "* * * * * *"))

      assert {:error, _} =
               call(ctx, %{"action" => "update", "schedule_id" => id, "cron_expression" => "nope"})

      assert {:error, _} = call(ctx, %{"action" => "pause", "schedule_id" => "sch_nobody"})

      Cyfr.Test.Settings.put("max_schedules_per_athanor", 1)
      assert {:error, "Schedule limit reached (1 per athanor)"} = call(ctx, create_args("over"))

      refute_receive %Schedules{}, 200
    end

    test "a feed's row is never announced", %{ctx: ctx, actor: actor} do
      {:ok, feed} = feed!(ctx, "btc")
      assert :ok = Changes.changed(actor, feed.id)
      refute_receive %Schedules{}, 200
    end

    test "no payload carries the row's input, metadata, profile, pinned reference or maker",
         %{ctx: ctx} do
      {:ok, %{schedule_id: id}} =
        call(
          ctx,
          create_args("private")
          |> Map.put("input", %{"secret" => @private_input})
          |> Map.put("metadata", %{"note" => @private_note})
        )

      assert_receive %Schedules{schedule_id: ^id} = payload
      {:ok, [item]} = Provider.live_schedules(ctx, nil)

      for heard <- [payload, item] do
        text = inspect(heard)
        refute text =~ @private_input
        refute text =~ @private_note
        refute text =~ "prof-cron"
        refute text =~ ctx.user_id
      end
    end
  end

  describe "the schedules' refresh" do
    test "is every live schedule, paused ones included, past any default bound, and no feed",
         %{ctx: ctx, actor: actor} do
      Cyfr.Test.Settings.put("max_schedules_per_athanor", 0)
      rows = for n <- 1..55, do: stored!(actor, "bulk-#{n}")

      paused = hd(rows)
      {:ok, _} = Arca.CronSchedule.update(actor, paused.id, %{status: "paused"})
      gone = List.last(rows)
      {:ok, _} = Arca.CronSchedule.soft_delete(actor, gone.id)
      {:ok, feed} = feed!(ctx, "eth")

      assert {:ok, items} = Provider.live_schedules(ctx, nil)
      wired = Enum.map(items, &read_as/1)

      assert length(wired) == 54
      assert Enum.all?(wired, &(&1["kind"] == "changed"))
      ids = Enum.map(wired, & &1["schedule_id"])
      assert paused.id in ids
      refute gone.id in ids
      refute feed.id in ids
      assert %{"status" => "paused"} = Enum.find(wired, &(&1["schedule_id"] == paused.id))

      assert {:error, :no_athanor} = Provider.live_schedules(%{ctx | athanor_id: nil}, nil)
      assert {:ok, []} = Provider.live_schedules(foreign(ctx), nil)
    end
  end

  describe "the schedule runs' refresh" do
    test "is the 20 newest occurrences of schedules, oldest first, a failed or uncertain one as failed",
         %{ctx: ctx, actor: actor} do
      schedule = stored!(actor, "runs")
      {:ok, feed} = feed!(ctx, "sol")

      states = ~w(claimed started completed failed uncertain)

      made =
        for n <- 1..25 do
          occurrence!(actor, schedule.id, minutes_ago(n), Enum.at(states, rem(n, 5)))
        end

      for n <- 1..3, do: occurrence!(actor, feed.id, DateTime.add(minutes_ago(0), n, :second))

      assert {:ok, items} = Provider.recent_runs(ctx, nil)
      wired = Enum.map(items, &read_as/1)

      newest_20 = made |> Enum.take(20) |> Enum.reverse()
      assert Enum.map(wired, & &1["occurrence_id"]) == Enum.map(newest_20, & &1.id)

      for {item, row} <- Enum.zip(wired, newest_20) do
        expected = if row.state in ["failed", "uncertain"], do: "failed", else: "fired"
        assert item["kind"] == expected, row.state
        assert item["schedule_id"] == schedule.id
        assert item["reason"] == nil
        assert item["execution_id"] == nil
        {:ok, due, 0} = DateTime.from_iso8601(item["scheduled_for"])
        assert DateTime.compare(due, row.scheduled_for) == :eq
      end

      assert {:error, :no_athanor} = Provider.recent_runs(%{ctx | athanor_id: nil}, nil)
    end

    test "a live fire and failure fit the shape the refresh is held to", %{actor: actor} do
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.schedule_runs(actor))
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.feed_runs(actor))
      due = ~U[2026-10-27 09:00:00.000000Z]

      :telemetry.execute([:cyfr, :schedules, :fired], %{}, %{
        athanor_id: actor.athanor_id,
        schedule_id: "sch_live",
        kind: "schedule",
        occurrence_id: "occ_live",
        scheduled_for: due,
        execution_id: "exec_live"
      })

      :telemetry.execute([:cyfr, :schedules, :failed], %{}, %{
        athanor_id: actor.athanor_id,
        schedule_id: "sch_live",
        kind: "schedule",
        reason: :damaged_reference
      })

      assert_receive %ScheduleRun{kind: :fired} = fired
      assert_receive %ScheduleRun{kind: :failed} = failed

      assert %{"scheduled_for" => "2026-10-27T09:00:00.000000Z", "occurrence_id" => "occ_live"} =
               read_as(fired)

      assert %{"occurrence_id" => nil, "scheduled_for" => nil, "reason" => %{"class" => _}} =
               read_as(failed)

      refute_received %FeedRun{}
    end
  end

  describe "a member that lost its slot" do
    setup do
      keys = [
        {Arca.ControlPlane, :standing},
        {Arca.ControlPlane, :generation},
        {Arca.ControlPlane, :slot}
      ]

      saved = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
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
      node = "node-streams-#{System.unique_integer([:positive])}"
      {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
      {:ok, slot: slot}
    end

    test "is refused the runs' refresh, :not_owner, and its refused writes announce nothing",
         %{ctx: ctx, actor: actor, slot: slot} do
      schedule = stored!(actor, "fenced")
      occurrence!(actor, schedule.id, minutes_ago(1), "completed")
      assert {:ok, [_]} = Provider.recent_runs(ctx, nil)

      {1, _} =
        Arca.Repo.update_all(
          from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
          set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1]
        )

      assert {:error, :not_owner} = Provider.recent_runs(ctx, nil)

      for action <- [
            %{"action" => "pause", "schedule_id" => schedule.id},
            %{"action" => "delete", "schedule_id" => schedule.id}
          ] do
        assert {:error, :not_owner} = call(ctx, action)
      end

      assert {:error, :not_owner} = call(ctx, create_args("fenced-again"))
      refute_receive %Schedules{}, 200
    end
  end

  # ---------------------------------------------------------------------------

  defp call(ctx, args), do: Provider.handle("schedule", ctx, args)

  defp create_args(name) do
    %{
      "action" => "create",
      "profile_id" => "prof-cron",
      "name" => name,
      "cron_expression" => "0 * * * *",
      "reference" => "reagent:local.test:1.0.0"
    }
  end

  # The next announcement of `id`, as a canvas reads it.
  defp heard(id) do
    assert_receive %Schedules{kind: :changed, schedule_id: ^id} = payload
    read_as(payload)
  end

  # A refresh item or a live payload as a canvas reads it on the stream
  # its topic feeds: projected by the grant, passed through JSON, and
  # held to the declared shape.
  defp read_as(%module{} = payload) do
    name = if module == Schedules, do: "schedules.changes", else: "schedule_runs.changes"
    {:ok, {Provider, stream}} = Sanctum.Catalog.lookup_stream(name)

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_streams"
    }

    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    data
  end

  defp stored!(actor, name) do
    {:ok, row} =
      Arca.CronSchedule.create(actor, %{
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        name: name,
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        input: Jason.encode!(%{"secret" => @private_input}),
        next_run_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        profile_id: "prof-cron",
        cap: 0
      })

    row
  end

  defp occurrence!(actor, schedule_id, at, state \\ "completed") do
    %Arca.Schemas.ScheduleOccurrence{}
    |> Arca.Schemas.ScheduleOccurrence.changeset(%{
      id: "occ_" <> String.pad_leading("#{System.unique_integer([:positive])}", 12, "0"),
      athanor_id: actor.athanor_id,
      schedule_id: schedule_id,
      scheduled_for: at,
      state: state,
      claimed_at: at
    })
    |> Arca.Repo.insert!()
  end

  defp minutes_ago(n), do: DateTime.add(~U[2026-10-27 12:00:00.000000Z], -n * 60, :second)

  defp foreign(ctx),
    do: %{ctx | athanor_id: "ath_streams_foreign", user_id: "local|local|streams-stranger"}

  defp feed!(ctx, name) do
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

    Arca.CronSchedule.create_feed(Context.actor(ctx), %{
      binding: binding,
      resolved_reference: "catalyst:local.markets:1.0.0",
      profile_id: "prof-cron",
      cap: 1_000
    })
  end
end
