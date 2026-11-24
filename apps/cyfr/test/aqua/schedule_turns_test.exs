# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleTurnsTest do
  @moduledoc """
  A schedule that holds a line for Aqua: who may make and change one, what
  its fire writes, the turn each fire becomes on the person's daily thread
  current when it fires (what it may do with nobody present, which day it
  joins), and the one end of its occurrence. The consumer is
  off in the suite (`:schedule_turns_enabled`), so each case drains by
  hand, which is what its wake-up and its tick do.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait
  import Cyfr.Test.Cron, only: [hourly_away: 0]

  alias Aqua.{Runner, ScheduleTurns, Tape}
  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ScheduleTurnDue
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Schedules.{Provider, Scheduler}

  @model "catalyst:local.claude"
  @aqua "agent:local.aqua"

  # At any instant the person's date in @east (UTC+14) is one or two days
  # after their date in @west (UTC-12): moving their zone from one to the
  # other crosses their midnight with no clock.
  @west "Etc/GMT+12"
  @east "Pacific/Kiritimati"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)

    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, ctx: ctx}
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp keep(id, name),
    do: call(id, "notes", %{"action" => "keep", "name" => name, "content" => "x"})

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # A key's call, a tincture's frame call and an MCP call carrying the
  # person's session: none is the person at their own signed-in screen.
  defp key(ctx), do: %{ctx | auth_method: :api_key, api_key_id: "key_x", origin: :programmatic}
  defp frame(ctx), do: %{ctx | auth_method: :tincture, frame: %{ref: "tincture:local.x"}}
  defp mcp(ctx), do: Sanctum.TestContext.via(ctx, :mcp)

  defp create(ctx, args) do
    Provider.handle(
      "schedule",
      ctx,
      Map.merge(
        %{
          "action" => "create",
          "name" => "sched-#{System.unique_integer([:positive])}",
          "cron_expression" => hourly_away()
        },
        args
      )
    )
  end

  # A schedule of the person's that holds `line` for Aqua.
  defp schedule!(ctx, name, line) do
    {:ok, %{schedule_id: id}} =
      create(ctx, %{"name" => name, "reference" => @aqua, "input" => %{"line" => line}})

    id
  end

  # A component's schedule, bound to a profile, written straight to its row.
  defp component!(ctx) do
    {:ok, row} =
      CronSchedule.create(actor(ctx), %{
        user_id: ctx.user_id,
        name: "comp-#{System.unique_integer([:positive])}",
        cron_expression: hourly_away(),
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        profile_id: "prof_test",
        input: Jason.encode!(%{"n" => 1}),
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cap: 1_000
      })

    row
  end

  defp row!(ctx, id) do
    {:ok, row} = CronSchedule.get(actor(ctx), id)
    row
  end

  # One occurrence of the schedule, due a moment ago, claimed by `boot` as
  # the scheduler claims it.
  defp fire!(ctx, id, boot \\ Prima.Boot.id()) do
    due = DateTime.add(DateTime.utc_now(), -2, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in Arca.Schemas.CronSchedule, where: s.id == ^id),
        set: [next_run_at: due]
      )

    cadence = %{
      next_after: &{:ok, DateTime.add(&1, 3600, :second)},
      missed_bound_ms: Scheduler.missed_bound_ms()
    }

    {:ok, occurrence} =
      ScheduleOccurrences.claim(%{row!(ctx, id) | next_run_at: due}, boot, cadence)

    occurrence
  end

  defp occurrence(ctx, id) do
    {:ok, row} = ScheduleOccurrences.get(actor(ctx), id)
    row
  end

  defp ended!(ctx, occurrence, state) do
    wait_until(
      fn -> occurrence(ctx, occurrence.id).state == state end,
      45_000,
      "occurrence #{occurrence.id} to be #{state}"
    )

    occurrence(ctx, occurrence.id)
  end

  defp client_id(occurrence), do: "#{occurrence.id}:#{occurrence.claimed_by}"

  # The turn the occurrence opened, in the daily thread that accepted its
  # line.
  defp turn_of(ctx, occurrence) do
    {:ok, %{thread_id: thread_id}} = Threads.daily_message(actor(ctx), client_id(occurrence))
    {:ok, %{turn: turn}} = Tape.accepted(ctx, thread_id, client_id(occurrence))
    turn
  end

  # The person's daily thread of their day now, made if none.
  defp today!(ctx) do
    {:ok, thread} = Aqua.Day.current(ctx)
    thread
  end

  defp zone!(ctx, zone), do: :ok = Aqua.put_reading(ctx.user_id, %{"time_zone" => zone})

  # Every thread of the athanor, by id.
  defp threads(ctx), do: ctx |> actor() |> Threads.list() |> Enum.map(& &1.id) |> Enum.sort()

  # The turns of a thread, in the order they were accepted.
  defp turns_in(thread_id) do
    Arca.Repo.all(
      from(t in Arca.Schemas.Turn,
        where: t.thread_id == ^thread_id,
        order_by: [asc: t.accepted_at, asc: t.id],
        select: t.id
      )
    )
  end

  # The messages of the thread a sender accepted under `client_id`.
  defp under_client_id(ctx, thread_id, client_id),
    do: Enum.filter(Threads.messages(actor(ctx), thread_id), &(&1.client_id == client_id))

  # A person's turn on `thread_id` whose model call the script holds on
  # its probes (`held/0`): the thread is busy until `release!/1` lets the
  # call answer. Each probe waits 5 s for its `:continue`, so a hold lasts
  # a minute at most.
  @probes 12
  defp held, do: List.duplicate({:probe, self()}, @probes)

  defp busy!(ctx, thread_id) do
    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread_id, "plan the day")
    assert_receive {:scripted_probe, player, _model_run}, 30_000
    {turn_id, player}
  end

  defp release!(player), do: for(_probe <- 1..@probes, do: send(player, :continue))

  defp await_status(ctx, turn_id, status) do
    wait_until(
      fn -> match?({:ok, %{status: ^status}}, Tape.turn(ctx, turn_id)) end,
      45_000,
      "turn #{turn_id} to be #{status}"
    )

    {:ok, turn} = Tape.turn(ctx, turn_id)
    turn
  rescue
    error in ExUnit.AssertionError ->
      {:ok, turn} = Tape.turn(ctx, turn_id)
      flunk("#{error.message}; it is #{turn.status} (#{inspect(turn.error)})")
  end

  defp steps(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.filter(steps, &(&1.kind == "tool"))
  end

  # What each tool step of the turn was and how it ended.
  defp outcomes(ctx, turn),
    do: Enum.map(steps(ctx, turn), &Map.take(&1, [:tool, :action, :outcome, :error]))

  # The thread's posts, as a person reads them.
  defp posts(ctx, thread_id) do
    for %{kind: kind} = row <- Threads.messages(actor(ctx), thread_id),
        kind in ~w(text error system),
        do: Map.take(row, [:kind, :author, :sent_by, :content, :client_id, :turn_id])
  end

  # A fire of a new schedule whose turn reads the day's threads, keeps a
  # note and answers, run to its end.
  defp fire_keeping!(ctx) do
    script!([call("t1", "threads", %{"action" => "list"}), keep("k1", "plan"), reply("Done.")])
    id = schedule!(ctx, "Keeper", "look, then keep the plan")
    occurrence = fire!(ctx, id)
    assert ScheduleTurns.drain() == %{occurrence.id => :sent}
    {id, occurrence, await_status(ctx, turn_of(ctx, occurrence).id, "completed")}
  end

  # ---------------------------------------------------------------------------

  describe "making one" do
    test "the person's own signed-in session makes a schedule hold a line for Aqua", %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "  summarise what is unread ")

      assert %{
               reference: @aqua,
               resolved_reference: @aqua,
               profile_id: nil,
               user_id: user_id,
               status: "active"
             } = row = row!(ctx, id)

      assert user_id == ctx.user_id
      assert Jason.decode!(row.input) == %{"line" => "summarise what is unread"}

      # The schedule names no thread: its fires join the person's day.
      refute Map.has_key?(row, :thread_id)
      assert threads(ctx) == []
    end

    test "a key, a tincture and an MCP call cannot make one, and nothing is written", %{ctx: ctx} do
      for caller <- [key(ctx), frame(ctx), mcp(ctx)] do
        assert create(caller, %{"reference" => @aqua, "input" => %{"line" => "hi"}}) ==
                 {:error, :aqua_line_by_person}
      end

      assert {:ok, []} = CronSchedule.list(actor(ctx), kind: "schedule")
    end

    test "no agent but Aqua, no profile and nothing but a line", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "A schedule holds a line only for Aqua" <> _}} =
               create(ctx, %{
                 "reference" => "agent:local.planner",
                 "profile_id" => "prof_x",
                 "input" => %{"line" => "x"}
               })

      assert {:error, {:invalid_argument, "A line for Aqua binds no profile"}} =
               create(ctx, %{
                 "reference" => @aqua,
                 "profile_id" => "prof_x",
                 "input" => %{"line" => "x"}
               })

      for input <- [nil, %{}, %{"line" => "  "}, %{"line" => "x", "extra" => 1}] do
        assert {:error, {:invalid_argument, _}} =
                 create(ctx, %{"reference" => @aqua, "input" => input})
      end

      assert {:ok, []} = CronSchedule.list(actor(ctx), kind: "schedule")
    end

    test "only the person turns a schedule into a line for Aqua or changes its line; anyone the tool admits pauses, resumes and deletes it",
         %{ctx: ctx} do
      component = component!(ctx)
      id = schedule!(ctx, "Morning", "summarise")

      for caller <- [key(ctx), frame(ctx), mcp(ctx)] do
        assert Provider.handle("schedule", caller, %{
                 "action" => "update",
                 "schedule_id" => component.id,
                 "reference" => @aqua,
                 "input" => %{"line" => "take over"}
               }) == {:error, :aqua_line_by_person}

        for change <- [%{"input" => %{"line" => "other"}}, %{"reference" => @aqua}] do
          assert Provider.handle(
                   "schedule",
                   caller,
                   Map.merge(%{"action" => "update", "schedule_id" => id}, change)
                 ) == {:error, :aqua_line_by_person}
        end
      end

      assert row!(ctx, component.id).reference == "reagent:local.test:1.0.0"
      assert Jason.decode!(row!(ctx, id).input) == %{"line" => "summarise"}

      # The person changes the line, and makes the component's schedule one.
      assert {:ok, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => id,
                 "input" => %{"line" => "summarise again"}
               })

      assert Jason.decode!(row!(ctx, id).input) == %{"line" => "summarise again"}

      assert {:ok, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => component.id,
                 "reference" => @aqua,
                 "input" => %{"line" => "now Aqua's"}
               })

      assert %{reference: @aqua, resolved_reference: @aqua, profile_id: nil} =
               row!(ctx, component.id)

      # Pausing, resuming and deleting are a schedule's ordinary writes.
      for action <- ~w(pause resume delete) do
        assert {:ok, _} =
                 Provider.handle("schedule", key(ctx), %{"action" => action, "schedule_id" => id})
      end

      assert row!(ctx, id).status == "deleted"
    end

    # Fires once, in the test's own process, right after the first read of
    # a schedule row: the key's update has read the row it decides on.
    @doc false
    def interleave(_event, _measurements, metadata, %{test: test, act: act}) do
      with true <- self() == test,
           :armed <- Process.get(:aqua_race),
           "cron_schedules" <- metadata[:source] do
        Process.put(:aqua_race, :fired)
        act.()
      end

      :ok
    end

    test "a key's change held after its read loses to the person turning the schedule into a line for Aqua",
         %{ctx: ctx} do
      component = component!(ctx)

      convert = fn ->
        {:ok, _} =
          Provider.handle("schedule", ctx, %{
            "action" => "update",
            "schedule_id" => component.id,
            "reference" => @aqua,
            "input" => %{"line" => "the person's line"}
          })
      end

      handler = "aqua-race-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.interleave/4, %{
          test: self(),
          act: convert
        })

      on_exit(fn -> :telemetry.detach(handler) end)
      Process.put(:aqua_race, :armed)

      assert Provider.handle("schedule", key(ctx), %{
               "action" => "update",
               "schedule_id" => component.id,
               "input" => %{"line" => "read every shared thread"}
             }) == {:error, :aqua_line_by_person}

      assert Process.get(:aqua_race) == :fired
      assert %{reference: @aqua} = row = row!(ctx, component.id)
      assert Jason.decode!(row.input) == %{"line" => "the person's line"}
    end

    test "a key's change after the person made the line is refused, by the tool and by the store",
         %{ctx: ctx} do
      component = component!(ctx)

      {:ok, _} =
        Provider.handle("schedule", ctx, %{
          "action" => "update",
          "schedule_id" => component.id,
          "reference" => @aqua,
          "input" => %{"line" => "the person's line"}
        })

      assert Provider.handle("schedule", key(ctx), %{
               "action" => "update",
               "schedule_id" => component.id,
               "input" => %{"line" => "read every shared thread"}
             }) == {:error, :aqua_line_by_person}

      # The store holds the rule itself, whoever calls it.
      for attrs <- [
            %{input: Jason.encode!(%{"line" => "x"})},
            %{reference: "reagent:local.test:1.0.0"},
            %{resolved_reference: "reagent:local.test:1.0.0"}
          ] do
        assert CronSchedule.update(actor(ctx), component.id, attrs) ==
                 {:error, :aqua_line_by_person}
      end

      assert {:error, :aqua_line_by_person} =
               CronSchedule.create(actor(ctx), %{
                 user_id: ctx.user_id,
                 name: "by-hand",
                 cron_expression: hourly_away(),
                 reference: @aqua,
                 resolved_reference: @aqua,
                 input: Jason.encode!(%{"line" => "x"}),
                 cap: 0
               })

      assert Jason.decode!(row!(ctx, component.id).input) == %{"line" => "the person's line"}

      assert {:ok, %{status: "paused"}} =
               CronSchedule.update(actor(ctx), component.id, %{status: "paused"})
    end

    test "no agent's call reaches making or changing one: both take the external plane alone" do
      [tool] = Provider.tools()

      for action <- ~w(create update) do
        assert %{planes: [:external]} = Enum.find(tool.operations, &(&1.action == action))
      end
    end
  end

  describe "firing" do
    setup %{ctx: ctx} do
      # The restore is registered before the change.
      Prima.Test.Env.put_app_env(:cyfr, :cron_scheduler_enabled, true)
      {:ok, ctx: ctx}
    end

    test "the scheduler claims a line for Aqua, wakes Aqua, and runs nothing itself", %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise what is unread")
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.schedule_turns())

      {1, _} =
        Arca.Repo.update_all(from(s in Arca.Schemas.CronSchedule, where: s.id == ^id),
          set: [next_run_at: DateTime.add(DateTime.utc_now(), -2, :second)]
        )

      start_supervised!(Scheduler)
      athanor_id = ctx.athanor_id
      assert_receive %ScheduleTurnDue{kind: :due, athanor_id: ^athanor_id}, 15_000

      boot = Prima.Boot.id()

      assert {:ok, [%{state: "claimed", claimed_by: ^boot, execution_id: nil}]} =
               ScheduleOccurrences.list(actor(ctx), id)

      # No run and no decision of the scheduler's own: the turn's root is
      # the fire's run, and its admission the fire's decision.
      assert Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.schedule_id == ^id)) == []
      assert Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == "schedule")) == []
    end
  end

  describe "a fire's turn" do
    test "a line that says \"summarise what is unread\" is answered on the daily thread current when it fires, in the server's voice naming the schedule, and makes no thread",
         %{ctx: ctx} do
      script!([call("t1", "threads", %{"action" => "list"}), reply("Nothing is unread.")])

      id = schedule!(ctx, "Morning", "summarise what is unread")
      %{id: thread_id} = today!(ctx)
      occurrence = fire!(ctx, id)

      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = turn_of(ctx, occurrence)
      turn = await_status(ctx, turn.id, "completed")

      assert %{origin: "schedule", agent: "aqua", requested_by: user_id, thread_id: ^thread_id} =
               turn

      assert user_id == ctx.user_id

      # Aqua's turn, on the brain and model of the crew member Aqua runs on
      # (`Cyfr.Test.SeedBundle.seat!/2`): Aqua's file names none of its own.
      # Its model calls run under the brain's own grant.
      assert "catalyst:local.claude:" <> _ = turn.catalyst_ref

      assert [{@model, "claude-sonnet-5-5"}] =
               Enum.uniq(
                 for %{input: %{"operation" => "chat"} = input, authority: authority} <-
                       ScriptedWorker.calls(),
                     do: {hd(authority.chain), input["params"]["model"]}
               )

      assert threads(ctx) == [thread_id]
      refute Map.has_key?(row!(ctx, id), :thread_id)

      # The line is the server's, sent for the person, naming the schedule;
      # it is a post the person has not seen, and the answer another.
      assert [line, answer] =
               Enum.filter(Threads.messages(actor(ctx), thread_id), &(&1.kind == "text"))

      assert Map.take(line, [:author, :sent_by, :addressee, :content, :client_id, :turn_id]) ==
               %{
                 author: Prima.Author.system(),
                 sent_by: "person",
                 addressee: "aqua",
                 content: "summarise what is unread",
                 client_id: client_id(occurrence),
                 turn_id: turn.id
               }

      assert Threads.payload(line) == %{"schedule" => %{"id" => id, "name" => "Morning"}}

      assert Map.take(answer, [:author, :sent_by, :content, :turn_id]) == %{
               author: Prima.Author.agent(),
               sent_by: "aqua",
               content: "Nothing is unread.",
               turn_id: turn.id
             }

      {:ok, thread} = Threads.get(actor(ctx), thread_id)
      assert %{kind: "daily", read_seq: 0} = thread
      assert Threads.unread(actor(ctx), thread) == {:ok, 2}

      assert [%{tool: "threads", action: "list", outcome: "ok"}] = steps(ctx, turn)

      assert %{state: "completed", execution_id: root} = ended!(ctx, occurrence, "completed")
      assert root == turn.root_execution_id
      assert %{run_count: 1, last_error: nil, last_execution_id: ^root} = row!(ctx, id)

      # The root names the schedule and the decision it was admitted under,
      # and that decision is the schedule's fire, naming the occurrence.
      # Its caller is the agent, nearer than the schedule its turn ran on.
      assert %{schedule_id: ^id, call_id: call_id, origin: "schedule", caller: "agent:aqua"} =
               Arca.Execution.get_tenant(actor(ctx), root)

      wait_until(fn -> match?({:ok, _}, Arca.DecisionLog.get(actor(ctx), call_id)) end, 5_000)

      assert {:ok, %{tool: "schedule", action: "fire", admission: :admitted}} =
               Arca.DecisionLog.get(actor(ctx), call_id)

      wait_until(fn -> Arca.McpLog.get_tenant(actor(ctx), call_id) != nil end, 5_000)
      logged = Arca.McpLog.get_tenant(actor(ctx), call_id)

      assert Jason.decode!(logged.input) == %{
               "schedule_id" => id,
               "occurrence_id" => occurrence.id,
               "reference" => @aqua
             }

      # Drained again, the occurrence is done and opens nothing.
      assert ScheduleTurns.drain() == %{}
      assert turns_in(thread_id) == [turn.id]
    end

    test "two fires and the person's own line are turns of the day's thread, run one at a time in the order they were accepted",
         %{ctx: ctx} do
      script!(held() ++ [reply("Planned."), reply("First."), reply("Second.")])

      first = schedule!(ctx, "First", "say first")
      second = schedule!(ctx, "Second", "say second")
      %{id: thread_id} = today!(ctx)
      {mine, player} = busy!(ctx, thread_id)

      # Behind the person's turn, each fire is a turn of its own, waiting:
      # neither steers the turn there.
      a = fire!(ctx, first)
      assert ScheduleTurns.drain() == %{a.id => :sent}
      b = fire!(ctx, second)
      assert ScheduleTurns.drain() == %{a.id => :waiting, b.id => :sent}

      %{id: a_turn} = turn_of(ctx, a)
      %{id: b_turn} = turn_of(ctx, b)
      assert turns_in(thread_id) == [mine, a_turn, b_turn]

      for {turn_id, status} <- [{mine, "running"}, {a_turn, "accepted"}, {b_turn, "accepted"}] do
        assert {:ok, %{status: ^status}} = Tape.turn(ctx, turn_id)
      end

      release!(player)

      ended =
        for turn_id <- [mine, a_turn, b_turn] do
          await_status(ctx, turn_id, "completed").ended_at
        end

      assert ended == Enum.sort(ended, DateTime)

      assert for(
               %{kind: "text", author: author} = row <- Threads.messages(actor(ctx), thread_id),
               author == Prima.Author.agent(),
               do: {row.content, row.turn_id}
             ) == [{"Planned.", mine}, {"First.", a_turn}, {"Second.", b_turn}]

      assert %{state: "completed"} = ended!(ctx, a, "completed")
      assert %{state: "completed"} = ended!(ctx, b, "completed")
      assert threads(ctx) == [thread_id]
    end

    test "a fire the day's thread cannot take yet waits for the next drain, and is sent once it can",
         %{ctx: ctx} do
      # The person's turn never hears from its model.
      script!([{:probe, self()}, :hang, reply("Late.")])

      %{id: thread_id} = today!(ctx)
      {_mine, player} = busy!(ctx, thread_id)
      send(player, :continue)

      # Eight fires wait behind the person's turn: the thread's queue is
      # full. A claim drained again answers the turn its first send opened.
      queued =
        Enum.reduce(1..8, [], fn n, queued ->
          occurrence = fire!(ctx, schedule!(ctx, "Queued #{n}", "wait"))

          assert ScheduleTurns.drain() ==
                   queued |> Map.new(&{&1.id, :waiting}) |> Map.put(occurrence.id, :sent)

          [occurrence | queued]
        end)

      late = fire!(ctx, schedule!(ctx, "Late", "say it late"))
      waiting = Map.new(queued, &{&1.id, :waiting})

      for _drain <- 1..2 do
        assert ScheduleTurns.drain() == Map.put(waiting, late.id, {:wait, :busy})
      end

      assert %{state: "claimed", execution_id: nil} = occurrence(ctx, late.id)
      assert {:error, :not_found} = Threads.daily_message(actor(ctx), client_id(late))

      # The person stops their turn and the turns queued behind it, whose
      # occurrences end with them; the one that waited is sent.
      :ok = Runner.stop_turn(ctx, thread_id)
      for occurrence <- queued, do: ended!(ctx, occurrence, "failed")
      assert ScheduleTurns.drain() == %{late.id => :sent}

      turn = await_status(ctx, turn_of(ctx, late).id, "completed")
      assert turn.thread_id == thread_id
      assert List.last(Threads.messages(actor(ctx), thread_id)).content == "Late."
      assert %{state: "completed"} = ended!(ctx, late, "completed")
    end

    test "a fire's turn keeps the note: its read and its write run, and the turn goes on to its reply with nobody asked",
         %{ctx: ctx} do
      {id, occurrence, turn} = fire_keeping!(ctx)
      system = Prima.Author.system()

      assert %{error: nil, paused_at: nil} = turn

      assert outcomes(ctx, turn) == [
               %{tool: "threads", action: "list", outcome: "ok", error: nil},
               %{tool: "notes", action: "keep", outcome: "ok", error: nil}
             ]

      assert {:ok, %{notes: [%{name: "plan"}]}} = Aqua.Notes.list(ctx)

      assert posts(ctx, turn.thread_id) == [
               %{
                 kind: "text",
                 author: system,
                 sent_by: "person",
                 content: "look, then keep the plan",
                 client_id: client_id(occurrence),
                 turn_id: turn.id
               },
               %{
                 kind: "text",
                 author: Prima.Author.agent(),
                 sent_by: "aqua",
                 content: "Done.",
                 client_id: nil,
                 turn_id: turn.id
               }
             ]

      assert %{state: "completed", execution_id: root} = ended!(ctx, occurrence, "completed")
      assert root == turn.root_execution_id
      assert %{run_count: 1, last_error: nil} = row!(ctx, id)
      assert {:ok, []} = Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id)
    end

    test "a fire's turn that fails once it started ends its occurrence failed, says why on the " <>
           "schedule and in its attention item, and is told as a failed fire",
         %{ctx: ctx} do
      script!([{:error, "the model could not be reached"}])
      handler = "schedule-failed-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :schedules, :failed],
          fn _event, measurements, meta, _ -> send(test, {:failed, measurements, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = schedule!(ctx, "Planner", "plan the day")
      claimed = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{claimed.id => :sent}

      turn = await_status(ctx, turn_of(ctx, claimed).id, "failed")
      assert %{error: "the model could not be reached", root_execution_id: root} = turn
      assert is_binary(root)

      ended = ended!(ctx, claimed, "failed")
      assert %DateTime{} = ended.ended_at
      # Its start took the claim's one attempt and bound the turn's root.
      assert ended == %{
               claimed
               | state: "failed",
                 execution_id: root,
                 attempts: claimed.attempts + 1,
                 ended_at: ended.ended_at
             }

      said = "Last run failed: the model could not be reached"
      assert %{run_count: 0, last_error: ^said, kind: kind} = row!(ctx, id)
      occurrence_id = claimed.id
      assert_receive {:failed, measurements, %{occurrence_id: ^occurrence_id} = meta}, 5_000
      assert measurements == %{count: 1}

      assert meta == %{
               schedule_id: id,
               kind: kind,
               occurrence_id: claimed.id,
               scheduled_for: claimed.scheduled_for,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               execution_id: root,
               reason: said
             }

      assert Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id) ==
               {:ok,
                [
                  %{
                    kind: :failed_schedule,
                    id: id,
                    label: "Planner",
                    since: claimed.scheduled_for,
                    destination: %{kind: "page", page: "schedules", ref: id},
                    outcome: nil
                  }
                ]}
    end

    # An app of the person's own, granted with nothing to bind.
    defp app!(ctx) do
      ref = published!(ctx)
      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
      decisions = %{ref: ref, bindings: []}
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      ref
    end

    defp published!(ctx) do
      name = "sched-app-#{System.unique_integer([:positive])}"
      manifest = %{"name" => name, "version" => "1.0.0", "type" => "reagent"}

      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: name,
          version: "1.0.0",
          type: "reagent",
          manifest: Jason.encode!(manifest)
        })

      "reagent:local." <> name
    end

    defp launches(ctx, turn) do
      {:ok, steps} = Tape.steps(ctx, turn)
      Enum.filter(steps, &(&1.kind == "launch"))
    end

    defp runs_of(ctx, ref) do
      Arca.Repo.all(
        from(e in Arca.Schemas.Execution,
          where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{ref}%"),
          select: e.id
        )
      )
    end

    test "a granted component runs with nobody there, whatever the turn has read",
         %{ctx: ctx} do
      app = app!(ctx)
      # The turn reads the person's pinned note before it launches.
      {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "We are planning a trip.")

      start_supervised!(
        {ScriptedWorker,
         ref: [@model, app],
         script: [
           call("r1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}),
           %{"answered" => true},
           reply("ran it")
         ]}
      )

      id = schedule!(ctx, "Runner", "run the app")
      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = await_status(ctx, turn_of(ctx, occurrence).id, "completed")

      assert [%{outcome: "ok", child_execution_id: root}] =
               launches(ctx, turn)

      assert runs_of(ctx, app) == [root]
      assert %{state: "completed"} = ended!(ctx, occurrence, "completed")

      # The launched root's caller is the agent, from the launch's stamp.
      # The turn's brain is a child of the turn's own root: it records
      # none and reads the root's, the agent over the schedule.
      assert %{caller: "agent:aqua"} = Arca.Execution.get_tenant(actor(ctx), root)

      assert [_ | _] =
               brains =
               Arca.Repo.all(
                 from(e in Arca.Schemas.Execution,
                   where:
                     e.root_execution_id == ^turn.root_execution_id and
                       like(e.reference, ^"#{@model}%")
                 )
               )

      for brain <- brains do
        assert brain.caller == nil
        assert {:ok, record} = Opus.Record.get(ctx, brain.id)
        assert Opus.Record.caller(record) == {:ok, {:agent, "aqua"}}
      end
    end

    test "a run of a component nobody has granted runs nothing, and the turn goes on to its reply",
         %{ctx: ctx} do
      app = published!(ctx)

      start_supervised!(
        {ScriptedWorker,
         ref: [@model, app],
         script: [
           call("r1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}),
           reply("It is not granted.")
         ]}
      )

      id = schedule!(ctx, "Ungranted", "run the new app")
      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = await_status(ctx, turn_of(ctx, occurrence).id, "completed")
      assert [launch] = launches(ctx, turn)

      assert Map.take(launch, [:outcome, :error]) == %{
               outcome: "error",
               error: "Consent required: #{app} has not been granted — grant it to run it"
             }

      assert runs_of(ctx, app) == []
      assert %{content: "It is not granted."} = List.last(posts(ctx, turn.thread_id))
      assert %{state: "completed"} = ended!(ctx, occurrence, "completed")
      assert %{last_error: nil} = row!(ctx, id)
    end

    test "a fire's turn that finds its claim another server's says so plainly, and ends nothing",
         %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise")
      occurrence = fire!(ctx, id)
      %{id: thread_id} = today!(ctx)

      # Another server's recovery took the claim over after this boot's
      # turn was sent.
      {1, _} =
        Arca.Repo.update_all(
          from(o in Arca.Schemas.ScheduleOccurrence, where: o.id == ^occurrence.id),
          set: [claimed_by: "boot-elsewhere"]
        )

      {:ok, person} = Sanctum.Tenancy.continuation(ctx.user_id, ctx.athanor_id, "schedule")

      {:ok, %{turn_id: refused}} =
        Runner.send_message(person, thread_id, "summarise",
          client_id: "#{occurrence.id}:#{Prima.Boot.id()}",
          schedule: %{schedule_id: id, occurrence_id: occurrence.id}
        )

      turn = await_status(ctx, refused, "failed")

      assert turn.error ==
               "This scheduled run was already taken up by another turn, so this one did not start."

      assert %{state: "claimed", claimed_by: "boot-elsewhere"} = occurrence(ctx, occurrence.id)
      assert row!(ctx, id).last_error == nil
    end
  end

  describe "no thread of its own" do
    test "each fire of a day joins that day's thread, made if none; a deleted day's thread is made again at the next fire; a deleted schedule leaves the thread",
         %{ctx: ctx} do
      script!([reply("One."), reply("Two."), reply("Three.")])

      id = schedule!(ctx, "Morning", "say something")
      first = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{first.id => :sent}
      %{thread_id: made} = await_status(ctx, turn_of(ctx, first).id, "completed")
      ended!(ctx, first, "completed")

      # The day had no thread: the fire made the day's, titled with its date.
      day = Aqua.Day.today(ctx)
      date = Date.to_iso8601(day)

      assert {:ok, %{kind: "daily", day: ^day, title: ^date, created_by: user_id}} =
               Threads.get(actor(ctx), made)

      assert user_id == ctx.user_id
      assert threads(ctx) == [made]

      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      assert %{thread_id: ^made} = await_status(ctx, turn_of(ctx, second).id, "completed")
      ended!(ctx, second, "completed")
      assert threads(ctx) == [made]

      assert {:ok, _} = Tape.delete_thread(ctx, made)
      third = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{third.id => :sent}
      %{thread_id: again} = await_status(ctx, turn_of(ctx, third).id, "completed")
      refute again == made
      assert {:ok, %{kind: "daily", day: ^day}} = Threads.get(actor(ctx), again)
      assert threads(ctx) == [again]
      refute Map.has_key?(row!(ctx, id), :thread_id)

      assert {:ok, %{deleted: true}} =
               Provider.handle("schedule", ctx, %{"action" => "delete", "schedule_id" => id})

      assert threads(ctx) == [again]
      assert length(Threads.messages(actor(ctx), again)) == 2
    end

    test "a component's schedule is untouched: its claim is no line for Aqua, and makes no thread or post",
         %{ctx: ctx} do
      component = component!(ctx)
      occurrence = fire!(ctx, component.id)

      assert ScheduleTurns.drain() == %{}
      assert %{state: "claimed", execution_id: nil} = occurrence(ctx, occurrence.id)
      assert threads(ctx) == []
      assert {:error, :not_found} = Threads.daily_message(actor(ctx), client_id(occurrence))
      assert %{run_count: 0, last_error: nil} = row!(ctx, component.id)
    end
  end

  describe "the day a fire joins" do
    test "a fire after the person's midnight joins the new day's thread, and the day before keeps its own",
         %{ctx: ctx} do
      script!([reply("Before."), reply("After.")])
      id = schedule!(ctx, "Morning", "say something")

      zone!(ctx, @west)
      first = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{first.id => :sent}
      %{thread_id: day_before} = await_status(ctx, turn_of(ctx, first).id, "completed")
      ended!(ctx, first, "completed")

      zone!(ctx, @east)
      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      %{thread_id: day_after} = await_status(ctx, turn_of(ctx, second).id, "completed")
      ended!(ctx, second, "completed")

      assert {:ok, %{kind: "daily", day: earlier}} = Threads.get(actor(ctx), day_before)
      assert {:ok, %{kind: "daily", day: later}} = Threads.get(actor(ctx), day_after)
      assert Date.compare(later, earlier) == :gt
      assert threads(ctx) == Enum.sort([day_before, day_after])

      for {thread_id, occurrence, answer} <- [
            {day_before, first, "Before."},
            {day_after, second, "After."}
          ] do
        assert [
                 %{content: "say something", client_id: client_id},
                 %{content: ^answer}
               ] = Threads.messages(actor(ctx), thread_id)

        assert client_id == client_id(occurrence)
      end
    end

    test "a fire accepted behind busy work before midnight and drained again after it is found in the thread that accepted it, and leaves nothing in the new day",
         %{ctx: ctx} do
      script!(held() ++ [reply("Planned."), reply("Fired.")])
      id = schedule!(ctx, "Morning", "say something")

      zone!(ctx, @west)
      %{id: day_before} = today!(ctx)
      {mine, player} = busy!(ctx, day_before)

      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}
      queued = turn_of(ctx, occurrence)
      assert %{thread_id: ^day_before, status: "accepted"} = queued

      # Midnight passes while the fire waits: drained again, it is sent to
      # the thread that accepted it, which answers the turn it opened.
      zone!(ctx, @east)
      assert ScheduleTurns.drain() == %{occurrence.id => :waiting}
      assert turn_of(ctx, occurrence).id == queued.id
      assert [_line] = under_client_id(ctx, day_before, client_id(occurrence))
      assert turns_in(day_before) == [mine, queued.id]
      assert threads(ctx) == [day_before]

      release!(player)
      await_status(ctx, mine, "completed")
      assert %{thread_id: ^day_before} = await_status(ctx, queued.id, "completed")
      assert %{state: "completed"} = ended!(ctx, occurrence, "completed")
      assert ScheduleTurns.drain() == %{}

      assert List.last(Threads.messages(actor(ctx), day_before)).content == "Fired."
      assert [_line] = under_client_id(ctx, day_before, client_id(occurrence))
      assert turns_in(day_before) == [mine, queued.id]
      assert threads(ctx) == [day_before]
    end
  end

  describe "a claim whose turn will not start" do
    test "a schedule paused since its claim ends it failed, as did not start", %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise")
      occurrence = fire!(ctx, id)
      {:ok, _} = Provider.handle("schedule", ctx, %{"action" => "pause", "schedule_id" => id})

      assert ScheduleTurns.drain() == %{occurrence.id => {:ended, "the schedule is paused"}}
      assert %{state: "failed", execution_id: nil} = occurrence(ctx, occurrence.id)
      assert row!(ctx, id).last_error == "Last run did not start: the schedule is paused"
    end

    test "a message of the person's that took the occurrence's id leaves it failed, never their turn",
         %{ctx: ctx} do
      script!([reply("Hello.")])
      id = schedule!(ctx, "Morning", "summarise")
      occurrence = fire!(ctx, id)
      %{id: thread_id} = today!(ctx)

      {:ok, %{turn_id: theirs}} =
        Runner.send_message(ctx, thread_id, "hello",
          client_id: "#{occurrence.id}:#{occurrence.claimed_by}"
        )

      await_status(ctx, theirs, "completed")

      assert ScheduleTurns.drain() ==
               %{occurrence.id => {:ended, "its message was taken by another"}}

      assert %{state: "failed"} = occurrence(ctx, occurrence.id)
    end

    test "a claim another boot holds is that boot's to start", %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise")
      occurrence = fire!(ctx, id, "boot-elsewhere")

      assert ScheduleTurns.drain() == %{}
      assert %{state: "claimed", claimed_by: "boot-elsewhere"} = occurrence(ctx, occurrence.id)
    end
  end

  describe "end_turn" do
    test "refuses an occurrence of a component's schedule", %{ctx: ctx} do
      component = component!(ctx)
      occurrence = fire!(ctx, component.id)

      assert Scheduler.end_turn(actor(ctx), occurrence.id, nil, "x") ==
               {:error, :not_an_aqua_line}

      assert %{state: "claimed"} = occurrence(ctx, occurrence.id)
    end

    test "ends nothing for an execution still running, another execution or another boot's claim",
         %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise")
      elsewhere = fire!(ctx, id, "boot-elsewhere")

      assert Scheduler.end_turn(actor(ctx), elsewhere.id, nil, "x") == {:error, :stale}
      assert %{state: "claimed"} = occurrence(ctx, elsewhere.id)

      {1, _} =
        Arca.Repo.update_all(
          from(o in Arca.Schemas.ScheduleOccurrence, where: o.id == ^elsewhere.id),
          set: [state: "failed"]
        )

      started = fire!(ctx, id)
      running = running_execution!(ctx)

      {:ok, 1} =
        Arca.Repo.transaction(fn ->
          ScheduleOccurrences.start!(actor(ctx), started.id, Prima.Boot.id(), running)
        end)

      assert Scheduler.end_turn(actor(ctx), started.id, running, nil) == {:error, :running}
      assert Scheduler.end_turn(actor(ctx), started.id, "exec_other", nil) == {:error, :stale}
      assert Scheduler.end_turn(actor(ctx), started.id, nil, "x") == {:error, :stale}
      assert %{state: "started"} = occurrence(ctx, started.id)
    end
  end

  # An execution of the schedule admitted and still running.
  defp running_execution!(ctx) do
    {:ok, %{execution: execution}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: @aqua,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          origin: :schedule
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    execution.id
  end
end
