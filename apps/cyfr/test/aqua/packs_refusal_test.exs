# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.PacksRefusalTest do
  @moduledoc """
  A program that loads the person's packs and did not open for them, told
  as the refusal says it (`Prima.Refusal`) wherever it is opened for them:
  Aqua's turn on it (`Aqua.Harness.Program`) and the list of its models on
  the Aqua page (`PrismWeb.AquaLive`).
  """
  use PrismWeb.ConnCase, async: false

  alias Aqua.Tape
  alias Arca.{Files, TurnStorage}
  alias Cyfr.Test.ScriptedBackends, as: Scripted

  @root :crypto.strong_rand_bytes(32)
  @skill "---\nname: a\ndescription: d\n---\n\nb\n"

  setup do
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    user = test_user()
    own = Sanctum.Test.People.athanor!(user.user_id)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(own)
    ctx = ready_athanor!(own.id, user.user_id)
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    row = brain_row!(ctx, "claude-code")

    {:ok,
     ctx: ctx, actor: Sanctum.Context.actor(ctx), fake: fake, thread: thread, row: row, user: user}
  end

  defp brain_row!(ctx, name) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json:
          Jason.encode!(%{
            "command" => Opus.Programs.Definition.brain(name).command,
            "env" => %{}
          })
      })

    row
  end

  defp accept!(ctx, thread, row, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, turn} =
      TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row.id, %{fence: turn.fence})

    turn
  end

  test "a turn on Claude Code whose packs could not be made ready says so",
       %{ctx: ctx, actor: actor, thread: thread, row: row, fake: fake} do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    Scripted.refuse_once(fake, "packs_hold", "unavailable")
    turn = accept!(ctx, thread, row, "hello")

    expected = Prima.Refusal.message(:packs_unready)

    assert {:failed, ^expected} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 30_000)
  end

  test "a turn on Claude Code whose packs moved at every try says so",
       %{ctx: ctx, actor: actor, thread: thread, row: row, fake: fake} do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    for _n <- 1..4, do: Scripted.hold(fake, "packs_hold")
    turn = accept!(ctx, thread, row, "hello")
    loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

    for n <- 1..4 do
      assert_receive {:held, "packs_hold", pid}, 10_000
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/n#{n}.md", "#{n}")
      send(pid, :go)
    end

    expected = Prima.Refusal.message(:packs_moved)
    assert {:failed, ^expected} = Task.await(loop, 30_000)
  end

  test "the list of Claude Code's models, its packs not made ready, says so",
       %{conn: conn, ctx: ctx, actor: actor, fake: fake, user: user} do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)

    {:ok, %{"created" => "claude-code"}} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => "claude-code",
        "title" => "Claude Code",
        "program" => "claude-code",
        "model" => "opus"
      })

    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/aqua?setup=1")
    Scripted.refuse_once(fake, "packs_hold", "unavailable")

    edit = "#aqua-card-claude-code-edit"
    Prima.Test.Wait.wait_until(fn -> has_element?(view, edit) end, 2_000, "Edit button")
    view |> element(edit) |> render_click()

    Prima.Test.Wait.wait_until(
      fn -> has_element?(view, ~s(#aqua-card-claude-code [data-test="listing-failed"])) end,
      5_000,
      "listing-failed rendered"
    )

    shown =
      view
      |> element(~s(#aqua-card-claude-code [data-test="listing-failed"]))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    Cyfr.Test.Sandbox.end_views()
    assert shown =~ Prima.Refusal.message(:packs_unready)
  end
end
