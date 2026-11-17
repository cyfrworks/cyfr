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
end
