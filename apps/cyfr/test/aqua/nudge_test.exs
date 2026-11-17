# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.NudgeTest do
  @moduledoc """
  The tick that nudges a quiet workspace thread and posts on its person's
  daily thread of one that waits on them (`Aqua.Nudge`), through the
  runner and a scripted model: what each turn's Aqua reads, that the next
  quiet period runs from the nudge's turn's end, and how a wait's post
  opens, steers or queues behind the daily thread's turns. The tick is off
  in the suite (`:nudge_enabled`), so each case ticks by hand, and a quiet
  period is made by moving the rows' stamps back, never by waiting.
  Storage's own rules and races are `Arca.NudgeStorageTest`'s.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Crew, Nudge, Tape}
  alias Aqua.Providers.Workspace
  alias Arca.Schemas.{Approval, Message, Thread, Turn, TurnStep}
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker

  @model "catalyst:local.claude"
  # At any instant the person's date in @east (UTC+14) is one or two days
  # after their date in @west (UTC-12).
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

  # ---- the server's post of a wait ------------------------------------------

  test "a workspace thread that waits on its person gets one post of the server's on today's daily thread, " <>
         "which Aqua answers in a turn of its own, and the post moves no wait",
       %{ctx: ctx, daily: daily} do
    script!([
      call("r1", "workspace", %{
        "action" => "report",
        "outcome" => "needs_you",
        "summary" => "Which account should the report go to?"
      }),
      reply("Asked."),
      reply("The moon report needs you."),
      reply("The moon report still waits on you.")
    ])

    {workspace, opening} = open!(ctx, daily)
    await_status(ctx, opening, "completed")
    assert state(ctx, workspace.id) == "needs_you"

    # The report lands on today's daily thread and its turn tells the
    # person; the daily thread is idle after it.
    assert {:ok, %{"applied" => 1}} = Crew.drain(ctx.athanor_id)
    {:ok, today} = Aqua.Day.current(ctx)
    [%{turn_id: told}] = Enum.filter(rows(ctx, today.id), &(&1.kind == "report"))
    await_status(ctx, told, "completed")
    assert {:ok, []} = Tape.open_turns(ctx, today.id)

    :ok = aged!(ctx)
    {:ok, waiting} = Threads.get(actor(ctx), workspace.id)
    assert %{"reminded:opened" => 1} = tick(ctx)

    assert [%{kind: "text", author: "system", sent_by: "system", turn_id: turn_id} = post] =
             posts(ctx, today.id)

    assert post.workspace_id == workspace.id
    assert post.client_id == Nudge.client_id(wait_of(waiting))
    assert post.content == Nudge.reminder_post("Moon report", "needs_you")
    assert Tape.payload(post)["waits_since"] == DateTime.to_iso8601(waiting.waits_since)

    await_status(ctx, turn_id, "completed")

    assert {:ok, %{origin: "schedule", sent_by: "system", agent: "aqua"} = turn} =
             Tape.turn(ctx, turn_id)

    assert turn.message_id == post.id
    assert Jason.decode!(turn.options) == %{"agent" => "aqua"}
    assert List.last(sent()) =~ server_line(post)
    assert List.last(sent()) =~ "Moon report"
    assert answers(ctx, today.id, turn_id) == ["The moon report still waits on you."]

    # The wait is as it was, and a later tick posts nothing more.
    assert {:ok, %{workspace_state: "needs_you", waits_since: since}} =
             Threads.get(actor(ctx), workspace.id)

    assert since == waiting.waits_since
    assert tick(ctx) == %{}
    assert ids(posts(ctx, today.id)) == [post.id]
  end

  test "a wait younger than the quiet period gets no post", %{ctx: ctx} do
    young = DateTime.add(DateTime.utc_now(), -(Nudge.quiet_seconds() - 60), :second)
    _wait = waiting!(ctx, "Moon report", "needs_you", young)

    assert tick(ctx) == %{}
    assert all_posts(ctx) == []
    assert {:error, :not_found} = Threads.day(actor(ctx), Aqua.Day.today(ctx))
  end

  test "a post while a person's turn runs on the daily thread is a turn of its own queued behind it, " <>
         "never a steer of it, and is answered after it",
       %{ctx: ctx} do
    script!([
      {:probe, self()},
      reply("Here is your day."),
      reply("The moon report waits on you.")
    ])

    _wait = waiting!(ctx, "Moon report")
    {:ok, today} = Aqua.Day.current(ctx)

    assert {:ok, %{admitted: :turn, turn_id: persons}} =
             Aqua.Runner.send_message(ctx, today.id, "What is on today?")

    assert_receive {:scripted_probe, player, _}, 60_000
    on_exit(fn -> send(player, :continue) end)

    got = tick(ctx)
    landed = posts(ctx, today.id)
    held = Aqua.Runner.state(today.id, ctx.athanor_id)
    queued = Enum.map(landed, &elem(Tape.turn(ctx, &1.turn_id), 1).status)
    send(player, :continue)

    assert got == %{"reminded:opened" => 1}
    assert [%{turn_id: own} = post] = landed
    refute own == persons
    assert queued == ["accepted"]
    assert %{running: true, turn_id: ^persons, queued: 1} = held

    await_status(ctx, persons, "completed")
    await_status(ctx, own, "completed")
    [first, second] = sent()
    refute first =~ json(post.content)
    assert second =~ server_line(post)
    assert answers(ctx, today.id, persons) == ["Here is your day."]
    assert answers(ctx, today.id, own) == ["The moon report waits on you."]
  end

  test "a post while an earlier post's turn holds a model call steers that turn, " <>
         "read at its next model round",
       %{ctx: ctx} do
    script!([{:probe, self()}, reply("The first waits on you."), reply("So does the second.")])
    first = waiting!(ctx, "First wait")
    second = waiting!(ctx, "Second wait", "error", DateTime.utc_now())

    assert tick(ctx) == %{"reminded:opened" => 1}
    assert_receive {:scripted_probe, player, _}, 60_000
    on_exit(fn -> send(player, :continue) end)

    # Both wait past the quiet period now; the first's post is the turn
    # at work.
    :ok = set!(second, waits_since: past())
    got = tick(ctx)
    {:ok, today} = Aqua.Day.current(ctx)
    landed = posts(ctx, today.id)
    send(player, :continue)

    assert got == %{"reminded:joined" => 1}

    assert [%{workspace_id: one, turn_id: turn_id} = opened, %{workspace_id: two} = steered] =
             landed

    assert one == first.id and two == second.id
    assert steered.turn_id == turn_id

    await_status(ctx, turn_id, "completed")
    [round_one, round_two] = sent()
    assert round_one =~ server_line(opened)
    refute round_one =~ json(steered.content)
    assert round_two =~ server_line(steered)
    assert answers(ctx, today.id, turn_id) == ["The first waits on you.", "So does the second."]
  end

  @tag :capture_log
  test "a post's turn paused on a call whose outcome is unknown is never steered by the next post, " <>
         "which queues behind it",
       %{ctx: ctx} do
    start_supervised!(
      {ScriptedWorker,
       ref: [@model, "catalyst:local.http"],
       script: [
         call("c1", "http", %{"action" => "get", "url" => "https://example.test/x"}),
         {:crash, :before_response},
         reply("Carrying on.")
       ]}
    )

    _first = waiting!(ctx, "First wait")
    second = waiting!(ctx, "Second wait", "error", DateTime.utc_now())
    {:ok, today} = Aqua.Day.current(ctx)
    :ok = Aqua.Runner.subscribe(today.id, ctx.athanor_id)

    assert tick(ctx) == %{"reminded:opened" => 1}
    assert [%{turn_id: paused} = opened] = posts(ctx, today.id)

    assert_receive %ThreadEvent{
                     kind: :turn_paused,
                     data: %{turn_id: ^paused, reason: :uncertain}
                   },
                   60_000

    :ok = set!(second, waits_since: past())
    assert tick(ctx) == %{"reminded:opened" => 1}
    assert [%{id: one}, %{turn_id: own}] = posts(ctx, today.id)
    assert one == opened.id
    refute own == paused

    assert %{paused: true, paused_reason: :uncertain, turn_id: ^paused, queued: 1} =
             Aqua.Runner.state(today.id, ctx.athanor_id)

    assert {:ok, %{status: "paused", paused_reason: "uncertain"}} = Tape.turn(ctx, paused)
    assert {:ok, %{status: "accepted"}} = Tape.turn(ctx, own)
  end

  test "a wait's post on the day is its receipt: a later tick, as after a lost answer or a restart, " <>
         "posts nothing, also once the workspace thread's title has changed",
       %{ctx: ctx} do
    script!([reply("The moon report waits on you.")])
    wait = waiting!(ctx, "Moon report")

    assert tick(ctx) == %{"reminded:opened" => 1}
    {:ok, today} = Aqua.Day.current(ctx)
    [post] = posts(ctx, today.id)
    await_status(ctx, post.turn_id, "completed")

    assert tick(ctx) == %{}
    :ok = set!(wait, title: "Sun report")
    assert tick(ctx) == %{}

    assert [%{id: id, content: content}] = posts(ctx, today.id)
    assert id == post.id
    assert content == Nudge.reminder_post("Moon report", "error")
  end

  test "a tick whose read missed the wait's post, landed since in other words, answers it posted " <>
         "and writes no second",
       %{ctx: ctx} do
    wait = waiting!(ctx, "Moon report")
    {:ok, today} = Aqua.Day.current(ctx)
    client_id = Nudge.client_id(wait_of(wait))

    # The tick has read the day's thread and its post waits at the
    # thread's runner while another send of the wait's post lands.
    holder = suspended!(ctx, today)
    ticking = Task.async(fn -> tick(ctx) end)
    assert await_send!(holder) == wait.id

    {:ok, _} =
      TurnStorage.accept_message(actor(ctx), today.id, %{
        message: %{
          author: Prima.Author.system(),
          sent_by: Prima.Author.system(),
          content: "Needs your attention: an earlier send.",
          client_id: client_id,
          workspace_id: wait.id
        }
      })

    :sys.resume(holder)
    assert Task.await(ticking, 30_000) == %{"reminded:posted" => 1}

    assert [%{client_id: ^client_id, content: "Needs your attention: an earlier send."}] =
             posts(ctx, today.id)
  end

  test "an athanor whose claim another boot holds is busy for the tick, which posts nothing " <>
         "until it is released",
       %{ctx: ctx} do
    script!([reply("The moon report waits on you.")])
    _wait = waiting!(ctx, "Moon report")
    {:ok, other} = Arca.JobClaims.claim("aqua_nudge", ctx.athanor_id, "boot_other", 60_000)

    assert tick(ctx) == :busy
    assert all_posts(ctx) == []

    assert :ok = Arca.JobClaims.release(other)
    assert tick(ctx) == %{"reminded:opened" => 1}
    assert [%{turn_id: turn_id}] = all_posts(ctx)
    await_status(ctx, turn_id, "completed")
  end

  test "a post refused as it is accepted leaves its wait for a later tick, which posts only that one",
       %{ctx: ctx} do
    script!([reply("One waits on you."), reply("The other too.")])
    waits = [waiting!(ctx, "First wait"), waiting!(ctx, "Second wait")]
    {:ok, today} = Aqua.Day.current(ctx)

    # The tick has read both waits, and its first post waits at the daily
    # thread's runner while that wait's workspace thread is archived.
    holder = suspended!(ctx, today)
    ticking = Task.async(fn -> tick(ctx) end)
    refused_id = await_send!(holder)
    [refused] = Enum.filter(waits, &(&1.id == refused_id))
    [other] = waits -- [refused]
    :ok = set!(refused, archived_at: DateTime.utc_now())
    :sys.resume(holder)

    assert Task.await(ticking, 30_000) == %{
             "reminded:thread_archived" => 1,
             "reminded:opened" => 1
           }

    assert [%{workspace_id: posted_id, turn_id: first}] = posts(ctx, today.id)
    assert posted_id == other.id
    await_status(ctx, first, "completed")

    # Out of the archive with its wait as it was: the next tick posts it
    # alone.
    :ok = set!(refused, archived_at: nil)
    assert tick(ctx) == %{"reminded:opened" => 1}

    assert [%{workspace_id: ^posted_id}, %{workspace_id: ^refused_id, turn_id: second}] =
             posts(ctx, today.id)

    await_status(ctx, second, "completed")
  end

  test "a wait is posted on each date of its person's: the tick makes today's daily thread for it, " <>
         "a new date's thread takes it again, and the first date's holds it once",
       %{ctx: ctx} do
    script!([reply("It waits on you."), reply("It still waits on you.")])
    wait = waiting!(ctx, "Moon report", "needs_you")

    :ok = Aqua.Day.put_zone(ctx.user_id, @west)
    first = Aqua.Day.today(ctx)
    assert {:error, :not_found} = Threads.day(actor(ctx), first)

    assert tick(ctx) == %{"reminded:opened" => 1}
    assert {:ok, west} = Threads.day(actor(ctx), first)
    assert [post] = posts(ctx, west.id)
    assert post.client_id == Nudge.client_id(wait_of(wait))
    await_status(ctx, post.turn_id, "completed")

    :ok = Aqua.Day.put_zone(ctx.user_id, @east)
    second = Aqua.Day.today(ctx)
    refute second == first
    assert tick(ctx) == %{"reminded:opened" => 1}
    assert {:ok, east} = Threads.day(actor(ctx), second)
    assert [again] = posts(ctx, east.id)
    assert again.client_id == Nudge.client_id(wait_of(wait))
    await_status(ctx, again.turn_id, "completed")
    assert ids(posts(ctx, west.id)) == [post.id]

    :ok = Aqua.Day.put_zone(ctx.user_id, @west)
    assert tick(ctx) == %{}
    assert Enum.sort(ids(all_posts(ctx))) == Enum.sort([post.id, again.id])
  end

  test "a post whose workspace thread's title names a crew member opens Aqua's turn " <>
         "and asks that member nothing",
       %{ctx: ctx} do
    script!([reply("The plan waits on you.")])
    member!(ctx, "planner")
    _wait = waiting!(ctx, "Ask @planner for the plan")

    assert tick(ctx) == %{"reminded:opened" => 1}
    {:ok, today} = Aqua.Day.current(ctx)
    assert [%{addressee: "aqua", turn_id: turn_id} = post] = posts(ctx, today.id)

    # The roster holds the member, and the post's words name it.
    assert {_text, %{"name" => "planner"}} =
             Aqua.Roster.parse_mention(post.content, Aqua.Roster.roster(ctx))

    assert {:ok, %{agent: "aqua"}} = Tape.turn(ctx, turn_id)
    await_status(ctx, turn_id, "completed")
    refute Enum.any?(rows(ctx, today.id), &(&1.addressee == "planner"))
    assert Threads.children(actor(ctx), today.id) == []
  end

  test "a wait decided or archived before the tick gets no post; one decided and archived after " <>
         "keeps its post, which a later turn of the daily thread reads as the server's line",
       %{ctx: ctx} do
    script!([reply("It waits on you."), reply("Nothing waits on you now.")])
    decided = waiting!(ctx, "Decided wait", "needs_you")
    archived = waiting!(ctx, "Archived wait")
    :ok = set!(decided, workspace_state: "done", workspace_outcome: "done")
    :ok = set!(archived, archived_at: DateTime.utc_now())

    assert tick(ctx) == %{}
    assert all_posts(ctx) == []

    kept = waiting!(ctx, "Kept wait", "needs_you")
    assert tick(ctx) == %{"reminded:opened" => 1}
    {:ok, today} = Aqua.Day.current(ctx)
    assert [%{workspace_id: named} = post] = posts(ctx, today.id)
    assert named == kept.id
    await_status(ctx, post.turn_id, "completed")

    :ok =
      set!(kept,
        workspace_state: "done",
        workspace_outcome: "done",
        archived_at: DateTime.utc_now()
      )

    assert tick(ctx) == %{}

    assert {:ok, %{turn_id: later}} =
             Aqua.Runner.send_message(ctx, today.id, "Anything for me?")

    await_status(ctx, later, "completed")
    assert ids(posts(ctx, today.id)) == [post.id]
    assert List.last(sent()) =~ server_line(post)
  end

  test "a post whose workspace thread is deleted before its turn runs is gone, " <>
         "and that turn's model never reads it",
       %{ctx: ctx} do
    script!([{:probe, self()}, reply("Here is your day."), reply("Nothing more.")])
    wait = waiting!(ctx, "Gone wait")
    {:ok, today} = Aqua.Day.current(ctx)

    assert {:ok, %{turn_id: persons}} =
             Aqua.Runner.send_message(ctx, today.id, "What is on today?")

    assert_receive {:scripted_probe, player, _}, 60_000
    on_exit(fn -> send(player, :continue) end)

    got = tick(ctx)
    landed = posts(ctx, today.id)
    deleted = Tape.delete_thread(ctx, wait.id)
    left = posts(ctx, today.id)
    send(player, :continue)

    assert got == %{"reminded:opened" => 1}
    assert [%{turn_id: queued} = post] = landed
    assert {:ok, %{cancelled: []}} = deleted
    assert left == []

    await_status(ctx, persons, "completed")
    await_status(ctx, queued, "completed")
    assert length(sent()) == 2
    refute Enum.any?(sent(), &(&1 =~ json(post.content)))
    refute Enum.any?(sent(), &(&1 =~ "Gone wait"))
  end

  test "a post a model has read is a source of its turn, and goes with its workspace thread, " <>
         "whose deletion forgets what the daily thread kept of it",
       %{ctx: ctx} do
    script!([reply("It waits on you.")])
    wait = waiting!(ctx, "Read wait")

    assert tick(ctx) == %{"reminded:opened" => 1}
    {:ok, today} = Aqua.Day.current(ctx)
    [post] = posts(ctx, today.id)
    await_status(ctx, post.turn_id, "completed")

    {:ok, %{sources: sources}} = Tape.turn(ctx, post.turn_id)
    assert Prima.Source.thread(wait.id) in Prima.Source.decode(sources)
    {:ok, %{brain_generation: generation}} = Threads.get(actor(ctx), today.id)

    assert {:ok, _} = Tape.delete_thread(ctx, wait.id)
    assert posts(ctx, today.id) == []
    assert answers(ctx, today.id, post.turn_id) == ["It waits on you."]
    assert {:ok, %{brain_generation: forgotten}} = Threads.get(actor(ctx), today.id)
    assert forgotten > generation
  end

  # A workspace thread of the athanor's reading `state` since `since`, its
  # wait begun past the quiet period unless named.
  defp waiting!(ctx, title, state \\ "error", since \\ past()) do
    id = Prima.UUID7.generate_id("thread")

    Arca.Repo.insert!(%Thread{
      id: id,
      athanor_id: ctx.athanor_id,
      created_by: ctx.user_id,
      kind: "workspace",
      title: title,
      workspace_state: state,
      workspace_outcome: state,
      waits_since: since
    })

    elem(Threads.get(actor(ctx), id), 1)
  end

  defp set!(thread, fields) do
    {1, _} =
      from(t in Thread, where: t.athanor_id == ^thread.athanor_id and t.id == ^thread.id)
      |> Arca.Repo.update_all(set: fields)

    :ok
  end

  defp wait_of(thread), do: %{workspace_id: thread.id, waits_since: thread.waits_since}

  # The server's posts on a daily thread, oldest first.
  defp posts(ctx, thread_id),
    do: Enum.filter(rows(ctx, thread_id), &(&1.kind == "text" and &1.author == "system"))

  # The server's posts on every thread of the athanor.
  defp all_posts(ctx) do
    from(m in Message,
      where: m.athanor_id == ^ctx.athanor_id and m.kind == "text" and m.author == "system"
    )
    |> Arca.Repo.all()
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # What Aqua said in a turn, oldest first.
  defp answers(ctx, thread_id, turn_id) do
    for %{turn_id: ^turn_id, author: author, content: content} <- rows(ctx, thread_id),
        author == Prima.Author.agent(),
        do: content
  end

  # `text` as a model's request spells it, inside a JSON string.
  defp json(text), do: text |> Jason.encode!() |> String.slice(1..-2//1)

  # The server's post as the model reads it.
  defp server_line(post), do: json("[A line from the server, not the person]\n" <> post.content)

  # The daily thread's runner, suspended until the test resumes it.
  defp suspended!(ctx, daily) do
    {:ok, holder} = Aqua.Runner.ensure(daily.id, ctx.athanor_id)
    :sys.suspend(holder)
    on_exit(fn -> if Process.alive?(holder), do: :sys.resume(holder) end)
    holder
  end

  # The tick's post waiting at the suspended runner `holder`: answers the
  # workspace thread it names.
  defp await_send!(holder) do
    sends = fn ->
      {:messages, msgs} = Process.info(holder, :messages)
      for {:"$gen_call", _, {:send, _, _, opts}} <- msgs, do: opts[:workspace_id]
    end

    wait_until(fn -> sends.() != [] end, 30_000, "the post waiting at the runner")
    [workspace_id] = sends.()
    workspace_id
  end

  # A crew member on the athanor's roster.
  defp member!(ctx, name) do
    :ok =
      Arca.put(
        actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{name}\ndescription: Plans.\navoid: Building.\n" <>
          "catalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n---\n\nYou are the #{name}.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
  end
end
