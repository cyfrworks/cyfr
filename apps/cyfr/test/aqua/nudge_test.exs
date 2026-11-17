# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.NudgeTest do
  @moduledoc """
  The tick that nudges a quiet workspace thread and reminds of one that
  waits on its person (`Aqua.Nudge`), through the runner and a scripted
  model: what the thread's Aqua reads, and that the next quiet period runs
  from the nudge's turn's end. The tick is off in the suite
  (`:nudge_enabled`), so each case ticks by hand, and a quiet period is
  made by moving the rows' stamps back, never by waiting. Storage's own
  rules and races are `Arca.NudgeStorageTest`'s.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Crew, Nudge, Tape}
  alias Aqua.Providers.Workspace
  alias Arca.Schemas.{Approval, Message, Thread, Turn, TurnStep}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedWorker

  @model "catalyst:local.claude"

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

    {:ok, daily} = Arca.Test.Days.thread(actor(ctx))
    {:ok, ctx: ctx, daily: daily}
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

  defp actor(ctx), do: Sanctum.Context.actor(ctx)
  defp rows(ctx, thread_id), do: Threads.messages(actor(ctx), thread_id)
  defp nudges(ctx, thread_id), do: Enum.filter(rows(ctx, thread_id), &(&1.kind == "nudge"))
  defp state(ctx, id), do: elem(Threads.get(actor(ctx), id), 1).workspace_state

  defp await_status(ctx, turn_id, status) do
    wait_until(
      fn -> match?({:ok, %{status: ^status}}, Tape.turn(ctx, turn_id)) end,
      45_000,
      "turn #{turn_id} to be #{status}"
    )
  end

  # The person opens a workspace thread from a post of the daily thread,
  # and the opening's delivery starts Aqua's turn there.
  defp open!(ctx, daily) do
    {:ok, %{message: asked}} =
      TurnStorage.accept_message(actor(ctx), daily.id, %{
        message: %{
          author: ctx.user_id,
          sent_by: "person",
          content: "please write the moon report"
        }
      })

    {:ok, %{workspace: id}} =
      Workspace.handle("workspace", ctx, %{
        "action" => "open",
        "title" => "Moon report",
        "thread" => daily.id,
        "refs" => [asked.id],
        "ask" => "write the moon report"
      })

    assert {:ok, %{"applied" => 1}} = Crew.drain(ctx.athanor_id)
    %{turn_id: turn_id} = Enum.find(rows(ctx, id), &(&1.kind == "opening"))
    {elem(Threads.get(actor(ctx), id), 1), turn_id}
  end

  # Everything the athanor's rows say happened, moved back past the quiet
  # period, and with `waits: true` when its waits began too: a wait's stamp
  # moved is another wait.
  defp aged!(ctx, opts \\ [waits: true]) do
    past = DateTime.add(DateTime.utc_now(), -(Nudge.quiet_seconds() + 60), :second)
    waits = if opts[:waits], do: [{Thread, [:waits_since]}], else: []

    for {schema, fields} <-
          [
            {Message, [:inserted_at]},
            {Turn, [:accepted_at, :ended_at]},
            {TurnStep, [:started_at, :ended_at]},
            {Approval, [:inserted_at, :decided_at]}
          ] ++ waits,
        field <- fields do
      from(r in schema, where: r.athanor_id == ^ctx.athanor_id and not is_nil(field(r, ^field)))
      |> Arca.Repo.update_all(set: [{field, past}])
    end

    :ok
  end

  defp tick(ctx), do: Map.get(Nudge.tick(), ctx.athanor_id, %{})

  # A further opening of the workspace thread from the daily thread's
  # person's post, under the schedule's narrower origin and tools.
  defp further!(ctx, daily, workspace) do
    asked = Enum.find(rows(ctx, daily.id), &(&1.sent_by == "person"))

    Workspace.handle("workspace", %{ctx | origin: :schedule}, %{
      "action" => "open",
      "title" => "Narrow next work",
      "thread" => daily.id,
      "refs" => [asked.id],
      "ask" => "only read the thread",
      "workspace" => workspace.id,
      "tools" => ["thread.events"]
    })
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -(Nudge.quiet_seconds() + 60), :second)

  # What each chat call of the model was sent, oldest first.
  defp sent do
    for %{input: %{"operation" => "chat"} = input} <- ScriptedWorker.calls(),
        do: Jason.encode!(input["params"]["messages"])
  end

  test "a workspace thread whose turn ended with nothing said is nudged after the quiet period, " <>
         "and the next quiet period runs from the nudge's turn's end",
       %{ctx: ctx, daily: daily} do
    script!([reply("On it."), reply("Still waiting on the build."), reply("Still waiting.")])
    {workspace, opening} = open!(ctx, daily)
    await_status(ctx, opening, "completed")
    assert state(ctx, workspace.id) == "open"

    assert tick(ctx) == %{}
    assert nudges(ctx, workspace.id) == []

    :ok = aged!(ctx)
    assert %{"opened" => 1} = tick(ctx)
    assert [%{sent_by: "system", turn_id: turn_id, content: line}] = nudges(ctx, workspace.id)
    assert line == Nudge.nudge_line()
    await_status(ctx, turn_id, "completed")

    assert List.last(sent()) =~ "A line from the server, not the person"

    assert List.last(sent()) =~ Nudge.nudge_line()

    # It ended with no report: the thread still works, and is not quiet
    # again until the quiet period has passed since that end.
    assert state(ctx, workspace.id) == "open"
    assert tick(ctx) == %{}

    :ok = aged!(ctx)
    assert %{"opened" => 1} = tick(ctx)
    assert [_, %{turn_id: again}] = nudges(ctx, workspace.id)
    await_status(ctx, again, "completed")
  end

  test "a nudge joins Aqua's turn at work there, read at that turn's next model round",
       %{ctx: ctx, daily: daily} do
    script!([{:probe, self()}, reply("Checked once."), reply("Still waiting on the build.")])
    {workspace, opening} = open!(ctx, daily)
    assert_receive {:scripted_probe, player, _execution}, 60_000

    :ok = aged!(ctx)
    assert %{"joined" => 1} = tick(ctx)
    assert [%{turn_id: ^opening}] = nudges(ctx, workspace.id)

    send(player, :continue)
    await_status(ctx, opening, "completed")

    [first, second] = sent()
    refute first =~ "A line from the server"
    assert second =~ Nudge.nudge_line()
    assert {:ok, []} = Tape.open_turns(ctx, workspace.id)
  end

  test "a nudge joins Aqua's turn at work there whatever is queued behind it",
       %{ctx: ctx, daily: daily} do
    script!([
      {:probe, self()},
      reply("Still waiting."),
      reply("Checked."),
      reply("Next work done.")
    ])

    {workspace, active} = open!(ctx, daily)
    assert_receive {:scripted_probe, player, _}, 60_000
    assert {:ok, _} = further!(ctx, daily, workspace)
    assert {:ok, %{"applied" => 1}} = Crew.drain(ctx.athanor_id)
    :ok = aged!(ctx)

    got = tick(ctx)
    landed = nudges(ctx, workspace.id)
    send(player, :continue)
    await_status(ctx, active, "completed")
    wait_until(fn -> Tape.open_turns(ctx, workspace.id) == {:ok, []} end, 45_000, "no turn open")

    assert got == %{"joined" => 1}
    assert [%{turn_id: ^active}] = landed
  end

  test "a nudge bound to work read before a narrower opening landed opens no turn under the older work",
       %{ctx: ctx, daily: daily} do
    script!([reply("On it."), reply("The older work's authority was used.")])
    {workspace, first} = open!(ctx, daily)
    await_status(ctx, first, "completed")
    :ok = aged!(ctx)

    # The tick has read the work and waits at the thread's runner while
    # the opening lands, written by a member whose clock is behind.
    {:ok, holder} = Aqua.Runner.ensure(workspace.id, ctx.athanor_id)
    :sys.suspend(holder)
    on_exit(fn -> if Process.alive?(holder), do: :sys.resume(holder) end)
    ticking = Task.async(fn -> tick(ctx) end)

    wait_until(
      fn ->
        {:messages, msgs} = Process.info(holder, :messages)
        Enum.any?(msgs, &match?({:"$gen_call", _, {:nudge, _, _}}, &1))
      end,
      5_000,
      "the nudge waiting at the runner"
    )

    assert {:ok, _} = further!(ctx, daily, workspace)

    from(m in Message,
      where: m.thread_id == ^workspace.id and m.kind == "opening" and is_nil(m.turn_id)
    )
    |> Arca.Repo.update_all(set: [inserted_at: past()])

    :sys.resume(holder)
    assert Task.await(ticking, 30_000) == %{"busy" => 1}
    assert nudges(ctx, workspace.id) == []
  end

  test "a workspace thread that needs the person is reminded once on the daily thread, " <>
         "by a turn of the daily thread's Aqua",
       %{ctx: ctx, daily: daily} do
    script!([
      call("r1", "workspace", %{
        "action" => "report",
        "outcome" => "needs_you",
        "summary" => "Which account should the report go to?"
      }),
      reply("Asked."),
      reply("The moon report needs you."),
      reply("A reminder: the moon report still needs you.")
    ])

    {workspace, opening} = open!(ctx, daily)
    await_status(ctx, opening, "completed")
    assert state(ctx, workspace.id) == "needs_you"

    # The report lands on today's daily thread and its turn tells the
    # person, as before.
    assert {:ok, %{"applied" => 1}} = Crew.drain(ctx.athanor_id)
    {:ok, today} = Aqua.Day.current(ctx)
    [%{turn_id: told}] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
    await_status(ctx, told, "completed")

    assert tick(ctx) == %{}
    :ok = aged!(ctx)
    assert %{"reminded:opened" => 1} = tick(ctx)

    assert [%{workspace_id: id, sent_by: "system", turn_id: reminding}] = nudges(ctx, today.id)
    assert id == workspace.id
    await_status(ctx, reminding, "completed")
    assert {:ok, %{origin: "schedule"}} = Tape.turn(ctx, reminding)
    assert List.last(sent()) =~ "A reminder from the server, not the person"
    assert List.last(sent()) =~ "needs the person"

    # Once a day: the next tick reminds of nothing.
    :ok = aged!(ctx, waits: false)
    assert tick(ctx) == %{}
    assert length(nudges(ctx, today.id)) == 1
  end

  test "one reminder names every wait of the athanor, whatever page of candidates it came on",
       %{ctx: ctx, daily: daily} do
    script!([
      reply("On it."),
      {:probe, self()},
      reply("These need you."),
      reply("More need you.")
    ])

    {workspace, first} = open!(ctx, daily)
    await_status(ctx, first, "completed")

    for i <- 1..100 do
      Arca.Repo.insert!(%Thread{
        id: Prima.UUID7.generate_id("thread"),
        athanor_id: ctx.athanor_id,
        created_by: ctx.user_id,
        kind: "workspace",
        title: "Waiting #{i}",
        workspace_state: "error",
        workspace_outcome: "error",
        waits_since: past()
      })
    end

    from(t in Thread, where: t.id == ^workspace.id)
    |> Arca.Repo.update_all(
      set: [workspace_state: "error", workspace_outcome: "error", waits_since: past()]
    )

    assert %{"reminded:opened" => 1} = tick(ctx)
    assert_receive {:scripted_probe, player, _}, 60_000
    {:ok, today} = Aqua.Day.current(ctx)
    first_rows = nudges(ctx, today.id)
    send(player, :continue)
    await_status(ctx, hd(first_rows).turn_id, "completed")

    assert tick(ctx) == %{}
    all = nudges(ctx, today.id)
    assert length(first_rows) == 101
    assert length(all) == 101
    assert [_one] = Enum.uniq(Enum.map(all, & &1.turn_id))
  end

  test "a reminder's turn that starts late leaves out what Aqua reads of a wait archived since",
       %{ctx: ctx, daily: daily} do
    script!([reply("On it one."), reply("On it two."), reply("These need you.")])
    {one, first} = open!(ctx, daily)
    await_status(ctx, first, "completed")
    {two, second} = open!(ctx, daily)
    await_status(ctx, second, "completed")
    ids = [one.id, two.id]
    since = past()

    from(t in Thread, where: t.id in ^ids)
    |> Arca.Repo.update_all(
      set: [workspace_state: "error", workspace_outcome: "error", waits_since: since]
    )

    {:ok, today} = Aqua.Day.current(ctx)
    {:ok, claim} = Arca.JobClaims.claim("aqua_nudge", ctx.athanor_id, Prima.Boot.id(), 60_000)
    {:ok, slot} = Arca.ControlPlane.member_slot()

    # Accepted and left for the runner to start, then the first thread is
    # archived.
    {:ok, %{turn: turn}} =
      Tape.remind(%{ctx | origin: :schedule}, today.id, %{
        claim: claim,
        slot: slot,
        waits: [
          %{workspace_id: one.id, waits_since: since, content: "ARCHIVED_WAIT needs you."},
          %{workspace_id: two.id, waits_since: since, content: "CURRENT_WAIT needs you."}
        ]
      })

    from(t in Thread, where: t.id == ^one.id)
    |> Arca.Repo.update_all(set: [archived_at: DateTime.utc_now()])

    {:ok, _} = Aqua.Runner.ensure(today.id, ctx.athanor_id)
    await_status(ctx, turn.id, "completed")
    assert List.last(sent()) =~ "CURRENT_WAIT"
    refute List.last(sent()) =~ "ARCHIVED_WAIT"
  end

  # SQLite's temporary trigger is the connection's own; on PostgreSQL a
  # refused write ends the sandbox's transaction, and with it the run.
  @tag :sqlite
  @tag :capture_log
  test "a reminder's turn writes nothing as it starts, so a write the store refuses passes no archived wait",
       %{ctx: ctx, daily: daily} do
    script!([reply("On it one."), reply("On it two."), reply("These need you.")])
    [one, two] = errored!(ctx, daily, 2)
    turn = reminded!(ctx, [{one, "ARCHIVED_WAIT"}, {two, "CURRENT_WAIT"}])
    archive!([one])

    Arca.Repo.query!(
      "CREATE TEMP TRIGGER nudge_test_refused BEFORE UPDATE OF status ON messages " <>
        "WHEN NEW.kind = 'nudge' BEGIN SELECT RAISE(ABORT, 'the store refuses the write'); END",
      []
    )

    {:ok, _} = Aqua.Runner.ensure(turn.thread_id, ctx.athanor_id)
    await_status(ctx, turn.id, "completed")
    refute Enum.any?(Enum.drop(sent(), 2), &String.contains?(&1, "ARCHIVED_WAIT"))
    assert List.last(sent()) =~ "CURRENT_WAIT"
  end

  test "a reminder none of whose waits stands as its turn starts completes with no model call",
       %{ctx: ctx, daily: daily} do
    script!([reply("On it one."), reply("On it two."), reply("These need you.")])
    waits = errored!(ctx, daily, 2)
    turn = reminded!(ctx, Enum.map(waits, &{&1, "GONE_WAIT"}))
    archive!(waits)

    {:ok, _} = Aqua.Runner.ensure(turn.thread_id, ctx.athanor_id)
    await_status(ctx, turn.id, "completed")
    assert length(sent()) == 2
  end

  test "the running turn a nudge joined never reads an opening still waiting for its own turn",
       %{ctx: ctx, daily: daily} do
    script!([{:probe, self()}, reply("Still waiting."), reply("Checked.")])
    {workspace, active} = open!(ctx, daily)
    assert_receive {:scripted_probe, player, _}, 60_000
    on_exit(fn -> send(player, :continue) end)
    assert {:ok, _} = further!(ctx, daily, workspace)
    :ok = aged!(ctx)

    assert %{"joined" => 1} = tick(ctx)
    send(player, :continue)
    await_status(ctx, active, "completed")

    [first, second] = Enum.take(sent(), 2)
    assert second =~ Nudge.nudge_line()
    refute first =~ "only read the thread"
    refute second =~ "only read the thread"
  end

  # `count` workspace threads whose turns ended, each then reading error
  # with a wait begun past the quiet period.
  defp errored!(ctx, daily, count) do
    threads =
      for _ <- 1..count do
        {thread, turn} = open!(ctx, daily)
        await_status(ctx, turn, "completed")
        thread
      end

    ids = Enum.map(threads, & &1.id)

    from(t in Thread, where: t.id in ^ids)
    |> Arca.Repo.update_all(
      set: [workspace_state: "error", workspace_outcome: "error", waits_since: past()]
    )

    Enum.map(threads, &elem(Threads.get(actor(ctx), &1.id), 1))
  end

  # The reminder of `waits` (`[{thread, word}]`) accepted on today's daily
  # thread and left for its runner to start.
  defp reminded!(ctx, waits) do
    {:ok, today} = Aqua.Day.current(ctx)
    {:ok, claim} = Arca.JobClaims.claim("aqua_nudge", ctx.athanor_id, Prima.Boot.id(), 60_000)
    {:ok, slot} = Arca.ControlPlane.member_slot()

    {:ok, %{turn: turn}} =
      Tape.remind(%{ctx | origin: :schedule}, today.id, %{
        claim: claim,
        slot: slot,
        waits:
          for {thread, word} <- waits do
            %{
              workspace_id: thread.id,
              waits_since: thread.waits_since,
              content: "#{word} needs you."
            }
          end
      })

    turn
  end

  defp archive!(threads) do
    ids = Enum.map(threads, & &1.id)

    from(t in Thread, where: t.id in ^ids)
    |> Arca.Repo.update_all(set: [archived_at: DateTime.utc_now()])
  end
end
