# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ScheduleTurnsTest do
  @moduledoc """
  A schedule that holds a line for Aqua: who may make and change one, what
  its fire writes, the turn each fire becomes in the schedule's own thread
  (what it may do with nobody present, where it stops), and the one end of
  its occurrence. The consumer is off in the suite
  (`:schedule_turns_enabled`), so each case drains by hand, which is what
  its wake-up and its tick do.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait
  import Cyfr.Test.Cron, only: [hourly_away: 0]

  alias Aqua.{Approvals, Runner, ScheduleTurns, Tape}
  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ScheduleTurnDue
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Schedules.{Provider, Scheduler}

  @model "catalyst:local.claude"
  @aqua "agent:local.aqua"

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

  # The turn the occurrence opened in its schedule's thread.
  defp turn_of(ctx, schedule_id, occurrence) do
    %{thread_id: thread_id} = row!(ctx, schedule_id)

    {:ok, %{turn: turn}} =
      Tape.accepted(ctx, thread_id, "#{occurrence.id}:#{occurrence.claimed_by}")

    turn
  end

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

  defp waiting_cards(ctx) do
    {:ok, rows} = Arca.TurnStorage.waiting_approvals(actor(ctx), DateTime.utc_now())
    rows
  end

  defp sentence(tool_action, allowable \\ true)

  defp sentence(tool_action, true),
    do:
      "This scheduled run needed your approval to use #{tool_action}, and nobody was here " <>
        "to give it. To allow it next time, ask Aqua for it once in this thread and choose " <>
        "\"for this schedule\" when it asks."

  defp sentence(tool_action, false),
    do:
      "This scheduled run needed your approval to use #{tool_action}, and nobody was here " <>
        "to give it. This cannot be allowed for a schedule: it needs you here."

  # One model answer holding several calls, in this order.
  defp calls(items),
    do: %{
      "content" =>
        Enum.map(items, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end),
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  # ---------------------------------------------------------------------------

  describe "making one" do
    test "the person's own signed-in session makes a schedule hold a line for Aqua", %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "  summarise what is unread ")

      assert %{
               reference: @aqua,
               resolved_reference: @aqua,
               profile_id: nil,
               thread_id: nil,
               user_id: user_id,
               status: "active"
             } = row = row!(ctx, id)

      assert user_id == ctx.user_id
      assert Jason.decode!(row.input) == %{"line" => "summarise what is unread"}
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
    test "a line that says \"summarise what is unread\" is answered in the person's own thread, named after the schedule",
         %{ctx: ctx} do
      script!([call("t1", "threads", %{"action" => "list"}), reply("Nothing is unread.")])

      id = schedule!(ctx, "Morning", "summarise what is unread")
      occurrence = fire!(ctx, id)

      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = turn_of(ctx, id, occurrence)
      turn = await_status(ctx, turn.id, "completed")
      assert %{origin: "schedule", agent: "aqua", requested_by: user_id} = turn
      assert user_id == ctx.user_id

      %{thread_id: thread_id} = row!(ctx, id)

      assert {:ok, %{kind: "own", title: "Morning", agent: "aqua", created_by: ^user_id}} =
               Threads.get(actor(ctx), thread_id)

      messages = Threads.messages(actor(ctx), thread_id)
      assert %{sent_by: "person", content: "summarise what is unread"} = hd(messages)
      assert List.last(messages).content == "Nothing is unread."

      assert [%{tool: "threads", action: "list", outcome: "ok"}] = steps(ctx, turn)

      assert %{state: "completed", execution_id: root} = ended!(ctx, occurrence, "completed")
      assert root == turn.root_execution_id
      assert %{run_count: 1, last_error: nil, last_execution_id: ^root} = row!(ctx, id)

      # The root names the schedule and the decision it was admitted under,
      # and that decision is the schedule's fire, naming the occurrence.
      assert %{schedule_id: ^id, call_id: call_id, origin: "schedule"} =
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

      assert length(Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.thread_id == ^thread_id))) ==
               1
    end

    test "at its first call that would ask, the turn stops with what it needed and how to allow it: no card, a failed occurrence, the schedule's attention item",
         %{ctx: ctx} do
      script!([keep("k1", "plan")])

      handler = "schedule-failed-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :schedules, :failed],
          fn _event, _measurements, meta, _ -> send(test, {:failed, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = schedule!(ctx, "Keeper", "keep the plan")
      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = await_status(ctx, turn_of(ctx, id, occurrence).id, "failed")
      said = sentence("notes.keep")
      assert turn.error == said

      assert [%{tool: "notes", action: "keep", outcome: "denied", approval_id: nil, error: ^said}] =
               steps(ctx, turn)

      assert waiting_cards(ctx) == []
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)

      assert %{state: "failed"} = ended!(ctx, occurrence, "failed")
      assert row!(ctx, id).last_error == "Last run failed: " <> said

      occurrence_id = occurrence.id
      assert_receive {:failed, %{schedule_id: ^id, occurrence_id: ^occurrence_id}}, 5_000

      assert {:ok, [%{kind: :failed_schedule, id: ^id, label: "Keeper"}]} =
               Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id)
    end

    test "an act no answer may stand for says it needs the person there, and offers no way to allow it",
         %{ctx: ctx} do
      script!([call("d1", "files", %{"action" => "delete", "path" => "data/plan.md"})])

      id = schedule!(ctx, "Cleaner", "delete the plan")
      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = await_status(ctx, turn_of(ctx, id, occurrence).id, "failed")
      assert turn.error == sentence("files.delete", false)
      assert [%{tool: "files", action: "delete", outcome: "denied"}] = steps(ctx, turn)
      assert waiting_cards(ctx) == []
      assert %{state: "failed"} = ended!(ctx, occurrence, "failed")
      assert row!(ctx, id).last_error == "Last run failed: " <> sentence("files.delete", false)
    end

    test "a call that ran before the one that asks keeps its result, and the asking call never runs",
         %{ctx: ctx} do
      script!([call("t1", "threads", %{"action" => "list"}), keep("k1", "plan")])

      id = schedule!(ctx, "Keeper", "look, then keep the plan")
      occurrence = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{occurrence.id => :sent}

      turn = await_status(ctx, turn_of(ctx, id, occurrence).id, "failed")
      assert turn.error == sentence("notes.keep")

      assert [
               %{tool: "threads", action: "list", outcome: "ok", result_message_id: result},
               %{tool: "notes", action: "keep", outcome: "denied", started_at: nil}
             ] = steps(ctx, turn)

      assert {:ok, %{content: content}} = Tape.message(ctx, result)
      assert content =~ "count"
      assert waiting_cards(ctx) == []
      assert {:ok, %{notes: []}} = Aqua.Notes.list(ctx)
      assert %{state: "failed"} = ended!(ctx, occurrence, "failed")
    end

    test "for this schedule, given in its thread, is honoured by its fire a week later, and by no other thread, schedule or interactive turn",
         %{ctx: ctx} do
      script!([
        reply("Nothing yet."),
        keep("k1", "plan"),
        reply("Kept."),
        keep("k2", "plan2"),
        reply("Kept again."),
        keep("k4", "plan4"),
        keep("k5", "plan5"),
        keep("k3", "plan3")
      ])

      id = schedule!(ctx, "Keeper", "keep the plan")
      first = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{first.id => :sent}
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      ended!(ctx, first, "completed")
      %{thread_id: thread_id} = row!(ctx, id)

      # The person, in the schedule's thread, asks once and answers "for
      # this schedule".
      {:ok, %{turn_id: asked}} = Runner.send_message(ctx, thread_id, "keep the plan")
      await_status(ctx, asked, "paused")
      [%{id: approval_id, thread_id: ^thread_id}] = waiting_cards(ctx)

      assert {:ok, %{decision: "approved"}} =
               Approvals.resolve(ctx, approval_id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :schedule
               })

      await_status(ctx, asked, "completed")

      assert {:ok,
              [
                %{
                  tool: "notes",
                  action: "keep",
                  effect: "allow",
                  scope: "thread",
                  lifecycle_kind: "schedule",
                  lifecycle_id: ^id,
                  expires_at: nil
                }
              ]} = Aqua.ToolGrants.for_thread(ctx, thread_id, "aqua")

      # A week of clock later, the next fire keeps its note with nobody there.
      {1, _} =
        Arca.Repo.update_all(
          from(g in Arca.Schemas.ToolGrant, where: g.thread_id == ^thread_id),
          set: [granted_at: DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)]
        )

      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      turn = await_status(ctx, turn_of(ctx, id, second).id, "completed")
      assert [%{tool: "notes", action: "keep", outcome: "ok"}] = steps(ctx, turn)
      assert %{state: "completed"} = ended!(ctx, second, "completed")
      assert waiting_cards(ctx) == []

      # The person's own turns ask again, in that thread and in another.
      {:ok, %{turn_id: again}} = Runner.send_message(ctx, thread_id, "keep another")
      await_status(ctx, again, "paused")
      assert [%{thread_id: ^thread_id}] = waiting_cards(ctx)
      :ok = Runner.stop_turn(ctx, thread_id)

      {:ok, plain} = Threads.create(actor(ctx))
      {:ok, %{turn_id: elsewhere}} = Runner.send_message(ctx, plain.id, "keep a plan")
      await_status(ctx, elsewhere, "paused")
      plain_id = plain.id
      assert [%{thread_id: ^plain_id}] = waiting_cards(ctx)
      :ok = Runner.stop_turn(ctx, plain.id)

      # Another schedule, in a thread of its own, is not allowed by it.
      other = schedule!(ctx, "Other", "keep the plan")
      third = fire!(ctx, other)
      assert ScheduleTurns.drain() == %{third.id => :sent}
      refute row!(ctx, other).thread_id == thread_id
      turn = await_status(ctx, turn_of(ctx, other, third).id, "failed")
      assert turn.error == sentence("notes.keep")
      assert %{state: "failed"} = ended!(ctx, third, "failed")

      # Deleted, the schedule takes its answer with it.
      assert {:ok, %{deleted: true}} =
               Provider.handle("schedule", ctx, %{"action" => "delete", "schedule_id" => id})

      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread_id, "aqua")
    end

    test "for this schedule ends with the schedule's thread, and is refused in a thread that is no schedule's",
         %{ctx: ctx} do
      script!([reply("Here."), keep("k1", "plan"), reply("Kept."), keep("k2", "plan2")])

      id = schedule!(ctx, "Keeper", "say something")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      %{thread_id: thread_id} = row!(ctx, id)

      {:ok, %{turn_id: asked}} = Runner.send_message(ctx, thread_id, "keep the plan")
      await_status(ctx, asked, "paused")
      [%{id: approval_id}] = waiting_cards(ctx)

      assert {:ok, %{decision: "approved"}} =
               Approvals.resolve(ctx, approval_id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :schedule
               })

      await_status(ctx, asked, "completed")

      assert {:ok, [%{lifecycle_kind: "schedule"}]} =
               Aqua.ToolGrants.for_thread(ctx, thread_id, "aqua")

      assert Aqua.schedule_thread?(ctx, thread_id)
      assert {:ok, _} = Tape.delete_thread(ctx, thread_id)

      assert Arca.Repo.all(from(g in Arca.Schemas.ToolGrant, where: g.thread_id == ^thread_id)) ==
               []

      # In a thread no schedule's line runs in, the same answer asked for by
      # hand is refused, and the card still waits.
      {:ok, plain} = Threads.create(actor(ctx))
      {:ok, %{turn_id: elsewhere}} = Runner.send_message(ctx, plain.id, "keep a plan")
      await_status(ctx, elsewhere, "paused")
      [%{id: plain_card}] = waiting_cards(ctx)

      assert Approvals.resolve(ctx, plain_card, %{
               decision: :approved,
               scope: :thread,
               lifecycle: :schedule
             }) == {:error, {:scope_not_permitted, :no_schedule}}

      assert [%{id: ^plain_card}] = waiting_cards(ctx)
      refute Aqua.schedule_thread?(ctx, plain.id)
      :ok = Runner.stop_turn(ctx, plain.id)
    end

    test "a call whose allow stops covering it as it dispatches stops the turn there, and nothing after it runs",
         %{ctx: ctx} do
      script!([
        reply("Here."),
        keep("k1", "plan"),
        reply("Kept."),
        calls([
          {"t1", "threads", %{"action" => "list"}},
          {"k2", "notes", %{"action" => "keep", "name" => "plan2", "content" => "x"}},
          {"n1", "notes", %{"action" => "list"}}
        ])
      ])

      handler = "schedule-failed-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :schedules, :failed],
          fn _event, _measurements, meta, _ -> send(test, {:failed, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = schedule!(ctx, "Keeper", "look, then keep the plan")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      %{thread_id: thread_id} = row!(ctx, id)

      # For this schedule, following no outside source.
      {:ok, %{turn_id: asked}} = Runner.send_message(ctx, thread_id, "keep the plan")
      await_status(ctx, asked, "paused")
      [%{id: approval_id}] = waiting_cards(ctx)

      assert {:ok, %{decision: "approved"}} =
               Approvals.resolve(ctx, approval_id, %{
                 decision: :approved,
                 scope: :thread,
                 lifecycle: :schedule
               })

      await_status(ctx, asked, "completed")

      # One answer: a read that brings in other people's words, the keep
      # its allow covered until then, and another automatic read.
      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      turn = await_status(ctx, turn_of(ctx, id, second).id, "failed")
      assert turn.error == sentence("notes.keep")

      assert [
               %{tool: "threads", action: "list", outcome: "ok"},
               %{tool: "notes", action: "keep", outcome: "denied", started_at: nil},
               %{tool: "notes", action: "list", started_at: nil} = never
             ] = steps(ctx, turn)

      refute never.outcome == "ok"
      assert {:ok, %{notes: [%{name: "plan"}]}} = Aqua.Notes.list(ctx)
      assert waiting_cards(ctx) == []

      second_id = second.id
      assert %{state: "failed"} = ended!(ctx, second, "failed")
      assert_receive {:failed, %{schedule_id: ^id, occurrence_id: ^second_id}}, 5_000

      assert {:ok, [%{kind: :failed_schedule, id: ^id}]} =
               Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id)
    end

    # The standing rows as a schedule turn's loop and its steps read them,
    # once the batch's model call is under way (`armed`). The loop's first
    # read after that is the batch's decision, which finds the answer for
    # threads.list: right after it, the answer is withdrawn, before any
    # call dispatches. A step's worker reads them once to take the policy
    # and, only for a call the policy asks for, again to judge the standing
    # answer: the worker that reads them twice is the read's, named to the
    # test. Nothing is held; every event is one the loop makes in order.
    @doc false
    def withdraw_at_decision(_event, _measurements, metadata, %{test: test, state: state}) do
      with "tool_grants" <- metadata[:source],
           true <- Agent.get(state, & &1.armed) do
        me = self()

        cond do
          loop?(me) ->
            if Agent.get_and_update(state, &{&1.withdrawn, %{&1 | withdrawn: true}}) == false do
              {1, _} =
                Arca.Repo.delete_all(
                  from(g in Arca.Schemas.ToolGrant,
                    where:
                      g.thread_id == ^Agent.get(state, & &1.thread_id) and g.tool == "threads"
                  )
                )

              send(test, :withdrawn)
            end

          loop?(List.first(Process.get(:"$callers", []))) ->
            reads =
              Agent.get_and_update(state, fn s ->
                n = Map.get(s.reads, me, 0) + 1
                {n, %{s | reads: Map.put(s.reads, me, n)}}
              end)

            if reads == 2, do: send(test, {:asking_worker, me})

          true ->
            :ok
        end
      end

      :ok
    end

    defp loop?(pid) when is_pid(pid),
      do: Enum.any?(Registry.keys(Aqua.RunnerRegistry, pid), &match?({:turn, _}, &1))

    defp loop?(_none), do: false

    # The soul's own file asks for `threads.list`, its grant walked again.
    defp soul_asks!(ctx, key) do
      path = Compendium.AquaPath.soul_file()
      {:ok, binary} = Arca.get(actor(ctx), path)
      {:ok, soul} = Compendium.AquaAgent.parse(Compendium.AquaPath.soul_name(), binary)
      soul = %{soul | tool_policy: Map.put(soul.tool_policy, key, "ask")}
      :ok = Arca.put(actor(ctx), path, Compendium.AquaAgent.serialize(soul))
      {:ok, _} = Compendium.AgentIndex.sync(ctx)

      decisions = %{ref: @aqua, selections: [%{dep: @model, label: "default"}]}
      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })
    end

    # A schedule whose thread holds "for this schedule" for threads.list,
    # which the soul asks for, and the parallel batch of its next fire held
    # at both calls' dispatch checks with that answer withdrawn: the read
    # reports the stop while its sibling's fetch is still running.
    defp withdrawn_mid_batch!(ctx, order \\ :read_first) do
      soul_asks!(ctx, "threads.list")
      read_call = {"t1", "threads", %{"action" => "list"}}
      fetch_call = {"h1", "http", %{"action" => "get", "url" => "https://example.test/a"}}

      batch =
        if order == :read_first, do: [read_call, fetch_call], else: [fetch_call, read_call]

      start_supervised!(
        {ScriptedWorker,
         ref: [@model, "catalyst:local.http"],
         script: [
           reply("Here."),
           {:probe, self()},
           calls(batch),
           {:probe, self()},
           %{"status" => 200, "body" => "a"}
         ]}
      )

      id = schedule!(ctx, "Lister", "list what is unread")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      ended!(ctx, first, "completed")
      %{thread_id: thread_id} = row!(ctx, id)

      # "For this schedule", following no outside source, as the card's
      # answer writes it; the thread has read nothing outside yet.
      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread_id,
          agent_name: "aqua",
          tool: "threads",
          action: "list",
          lifecycle_kind: "schedule",
          lifecycle_id: id
        })

      {:ok, state} =
        Agent.start_link(fn ->
          %{armed: false, withdrawn: false, thread_id: thread_id, reads: %{}}
        end)

      handler = "withdraw-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.withdraw_at_decision/4, %{
          test: self(),
          state: state
        })

      on_exit(fn -> :telemetry.detach(handler) end)

      # The next fire's turn has taken its policy and asks its model: from
      # here the loop's next read of the standing rows is the batch's
      # decision.
      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      assert_receive {:scripted_probe, model, _model_run}, 30_000
      Agent.update(state, &%{&1 | armed: true})
      send(model, :continue)

      # Decided with the answer, then withdrawn before anything dispatched;
      # the fetch's run is held by the script, and the read's worker, which
      # judges the standing answer again at its dispatch, reports the stop
      # and ends.
      assert_receive :withdrawn, 30_000
      assert_receive {:scripted_probe, player, fetch}, 30_000
      assert_receive {:asking_worker, read}, 30_000
      [{waiter, _}] = Registry.lookup(Opus.Registry, fetch)
      refute waiter == read
      wait_until(fn -> not Process.alive?(read) end, 30_000, "the read's worker to end")
      :telemetry.detach(handler)

      {id, second, waiter, player}
    end

    defp stopped_mid_batch!(ctx, id, second) do
      turn = await_status(ctx, turn_of(ctx, id, second).id, "failed")
      assert turn.error == sentence("threads.list")

      assert [
               %{tool: "threads", action: "list", outcome: "denied", error: denied},
               %{tool: "http", action: "get", dispatch_state: "uncertain", outcome: "uncertain"}
             ] = steps(ctx, turn)

      assert denied == sentence("threads.list")
      assert %{state: "failed"} = ended!(ctx, second, "failed")

      assert {:ok, [%{kind: :failed_schedule, id: ^id}]} =
               Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id)

      # The model was asked nothing after the batch.
      assert length(Enum.filter(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))) ==
               2

      turn
    end

    test "a sibling that dies after a parallel read reported the stop is marked uncertain, and the stop stands",
         %{ctx: ctx} do
      {id, second, waiter, player} = withdrawn_mid_batch!(ctx)

      Process.exit(waiter, :kill)
      send(player, :continue)

      stopped_mid_batch!(ctx, id, second)
    end

    test "the stop stands whichever of the two calls the answer names first",
         %{ctx: ctx} do
      {id, second, waiter, player} = withdrawn_mid_batch!(ctx, :fetch_first)

      Process.exit(waiter, :kill)
      send(player, :continue)

      turn = await_status(ctx, turn_of(ctx, id, second).id, "failed")
      assert turn.error == sentence("threads.list")

      assert %{dispatch_state: "uncertain"} =
               Enum.find(steps(ctx, turn), &(&1.tool == "http"))

      assert %{state: "failed"} = ended!(ctx, second, "failed")
    end

    test "a sibling whose run is lost after a parallel read reported the stop is marked uncertain, and the stop stands",
         %{ctx: ctx} do
      {id, second, _waiter, player} = withdrawn_mid_batch!(ctx)

      # The fetch's runner dies: its waiter answers an unknown outcome.
      Process.exit(player, :kill)

      turn = stopped_mid_batch!(ctx, id, second)

      # Marked from the waiter's own answer, not from a death.
      assert [
               _read,
               %{tool: "http", error: "Execution terminated: runner stopped without cleanup"}
             ] =
               steps(ctx, turn)
    end

    test "a turn ended failed with a step marked uncertain holds nothing back: the schedule's next turn there runs unrestricted",
         %{ctx: ctx} do
      {id, second, waiter, player} = withdrawn_mid_batch!(ctx)
      Process.exit(waiter, :kill)
      send(player, :continue)
      stopped_mid_batch!(ctx, id, second)

      ScriptedWorker.script([reply("Next.")])

      third = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{third.id => :sent}
      turn = await_status(ctx, turn_of(ctx, id, third).id, "completed")
      refute Tape.restricted?(ctx, turn)
      assert %{state: "completed"} = ended!(ctx, third, "completed")
    end

    test "an automatic read turned to never before it dispatches is refused, and the schedule's turn goes on",
         %{ctx: ctx} do
      script!([
        reply("Here."),
        {:probe, self()},
        calls([{"t1", "threads", %{"action" => "list"}}]),
        reply("Done without it.")
      ])

      id = schedule!(ctx, "Lister", "list what is unread")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      ended!(ctx, first, "completed")

      # The next fire's turn has taken its policy; while its model is asked,
      # the person answers threads.list "never".
      second = fire!(ctx, id)
      assert ScheduleTurns.drain() == %{second.id => :sent}
      assert_receive {:scripted_probe, player, _model_run}, 30_000

      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, %{
          scope: "agent",
          effect: "deny",
          agent_name: "aqua",
          tool: "threads",
          action: "list"
        })

      send(player, :continue)

      turn = await_status(ctx, turn_of(ctx, id, second).id, "completed")

      assert [
               %{
                 tool: "threads",
                 action: "list",
                 outcome: "denied",
                 error: "threads.list is not in the agent's policy"
               }
             ] =
               steps(ctx, turn)

      assert List.last(Threads.messages(actor(ctx), turn.thread_id)).content == "Done without it."
      assert %{state: "completed"} = ended!(ctx, second, "completed")
      assert {:ok, []} = Cyfr.Providers.Attention.failed_schedule(actor(ctx), ctx.user_id, id)
    end

    test "an agent-wide answer ending with the schedule is refused, even in the schedule's own thread, and the card waits",
         %{ctx: ctx} do
      script!([
        reply("Here."),
        call("w1", "files", %{"action" => "write", "path" => "data/plan.md", "content" => "x"})
      ])

      id = schedule!(ctx, "Writer", "say something")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      %{thread_id: thread_id} = row!(ctx, id)

      {:ok, %{turn_id: asked}} = Runner.send_message(ctx, thread_id, "write the plan")
      await_status(ctx, asked, "paused")
      [%{id: approval_id}] = waiting_cards(ctx)

      assert Approvals.resolve(ctx, approval_id, %{
               decision: :approved,
               scope: :always,
               lifecycle: :schedule
             }) == {:error, {:scope_not_permitted, :invalid_lifecycle}}

      assert [%{id: ^approval_id}] = waiting_cards(ctx)
      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread_id, "aqua")
      :ok = Runner.stop_turn(ctx, thread_id)
    end

    test "a fire's turn that finds its claim another server's says so plainly, and ends nothing",
         %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "summarise")
      occurrence = fire!(ctx, id)
      {:ok, thread_id} = CronSchedule.thread(actor(ctx), id, "aqua")

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

  describe "the schedule's thread" do
    test "a deleted thread is let go and the next fire makes a new one; a deleted schedule leaves its thread",
         %{ctx: ctx} do
      script!([reply("One."), reply("Two.")])

      id = schedule!(ctx, "Morning", "say something")
      first = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, first).id, "completed")
      ended!(ctx, first, "completed")
      %{thread_id: gone} = row!(ctx, id)

      assert {:ok, _} = Tape.delete_thread(ctx, gone)
      assert row!(ctx, id).thread_id == nil

      second = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, second).id, "completed")
      %{thread_id: made} = row!(ctx, id)
      refute made == gone
      assert {:ok, %{title: "Morning"}} = Threads.get(actor(ctx), made)

      assert {:ok, %{deleted: true}} =
               Provider.handle("schedule", ctx, %{"action" => "delete", "schedule_id" => id})

      assert {:ok, %{id: ^made}} = Threads.get(actor(ctx), made)
    end

    # A for-this-schedule answer is held by the schedule's row, not by its
    # line: it stands while the schedule does, whatever it holds.
    test "a new line or kind keeps the thread and the schedule's answers, and an Aqua line again goes back to its thread",
         %{ctx: ctx} do
      id = schedule!(ctx, "Morning", "say something")
      {:ok, thread_id} = CronSchedule.thread(actor(ctx), id, Prima.AgentRef.soul_name())

      {:ok, _} =
        Sanctum.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread_id,
          agent_name: "aqua",
          tool: "threads",
          action: "list",
          lifecycle_kind: "schedule",
          lifecycle_id: id
        })

      standing = fn ->
        {:ok, rows} = Arca.ToolGrantStorage.list_for_thread(actor(ctx), thread_id)
        Enum.filter(rows, &(&1.lifecycle_kind == "schedule" and &1.lifecycle_id == id))
      end

      assert [_allow] = standing.()

      assert {:ok, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => id,
                 "input" => %{"line" => "say something else"}
               })

      assert %{thread_id: ^thread_id} = row!(ctx, id)
      assert [_allow] = standing.()

      # Made a component's schedule, then Aqua's again.
      {:ok, _} =
        CronSchedule.update(
          actor(ctx),
          id,
          %{
            reference: "reagent:local.test:1.0.0",
            resolved_reference: "reagent:local.test:1.0.0",
            profile_id: "prof_test",
            input: Jason.encode!(%{"n" => 1})
          },
          by_person: true
        )

      assert %{thread_id: ^thread_id, reference: "reagent:local.test:1.0.0"} = row!(ctx, id)
      assert [_allow] = standing.()

      assert {:ok, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => id,
                 "reference" => @aqua,
                 "input" => %{"line" => "a new line"}
               })

      assert {:ok, ^thread_id} = CronSchedule.thread(actor(ctx), id, Prima.AgentRef.soul_name())
      assert [_allow] = standing.()
    end

    test "a thread named but gone is made again at the fire", %{ctx: ctx} do
      script!([reply("Here.")])
      id = schedule!(ctx, "Morning", "say something")

      {1, _} =
        Arca.Repo.update_all(from(s in Arca.Schemas.CronSchedule, where: s.id == ^id),
          set: [thread_id: "thread_gone"]
        )

      occurrence = fire!(ctx, id)
      ScheduleTurns.drain()
      await_status(ctx, turn_of(ctx, id, occurrence).id, "completed")
      assert %{thread_id: made} = row!(ctx, id)
      refute made == "thread_gone"
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
      {:ok, thread_id} = CronSchedule.thread(actor(ctx), id, "aqua")

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
