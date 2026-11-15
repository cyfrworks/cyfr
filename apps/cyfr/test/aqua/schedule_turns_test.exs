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

  defp sentence(tool_action),
    do:
      "This scheduled run needed your approval to use #{tool_action}, and nobody was here " <>
        "to give it. To allow it next time, ask Aqua for it once in this thread and choose " <>
        "\"for this schedule\" when it asks."

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
