# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramNameTest do
  @moduledoc """
  A crew member names its program by the row's name (`program: claude`),
  through the real loop and the real attendant, the test playing the
  brain's driver against the scripted backends service as
  `Aqua.ProgramTest` does. A turn resolves the name once, in its own
  athanor, and pins the row's id; from then on the turn reads its pin by
  id, as a resumed loop builds it too, so a row replaced under the same
  name is the next turn's and never the pinned turn's.
  """

  use PrismWeb.ConnCase, async: false

  alias Aqua.Tape
  alias Arca.McpServerStorage
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedBackends, as: Scripted

  @root :crypto.strong_rand_bytes(32)
  @session "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"

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

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => "coder",
        "title" => "Coder",
        "program" => "claude",
        "model" => "opus"
      })

    # A member holds no consent of its own: it runs under the crew's one
    # grant, Aqua's, which a program brain is no dependency of.

    {:ok, room} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, thread} = Threads.crew_thread(Sanctum.Context.actor(ctx), room.id, "coder")
    {:ok, ctx: ctx, fake: fake, thread: thread}
  end

  test "a turn runs on the row of its member's program name in its own athanor, pinned by id; " <>
         "a row replaced under that name is the next turn's, never the pinned turn's",
       %{ctx: ctx, fake: fake, thread: thread} do
    # Another athanor holds a row of the same name: it is never this one's.
    other = test_user()
    elsewhere = Sanctum.Test.People.athanor!(other.user_id)
    theirs = row!(%{ctx | user_id: other.user_id, athanor_id: elsewhere.id})
    first = row!(ctx)

    turn = accept!(ctx, thread, "first")
    loop = run(ctx, turn)
    completed!(fake, first, turn, loop, "boot-one")

    assert {:ok, %{program: pinned, status: "completed"}} = Tape.turn(ctx, turn.id)
    assert pinned == first.id
    assert Scripted.sessions(fake, theirs.id) == %{}

    # The row is replaced under the same name, as the Programs page
    # removes one, once the turn's session ended with it.
    assert Enum.all?(Scripted.sessions(fake, first.id), fn {_id, session} ->
             not session.running
           end)

    assert {:ok, _} = McpServerStorage.delete(Sanctum.Context.actor(ctx), "claude")
    :ok = Opus.Programs.end_mounts(ctx.athanor_id, first.id)

    second = row!(ctx)
    refute second.id == first.id

    # The pinned turn, built again as a resumed loop builds it, reads its
    # pin by id and never resolves the name again: its row is gone, said
    # as the member's card says it (`Prima.Refusal`).
    assert {:error, {:crew_unready, "Coder", :program_missing}} = build(ctx, turn)

    # The next turn resolves the name once more and runs on the new row.
    next = accept!(ctx, thread, "second")
    loop = run(ctx, next)
    completed!(fake, second, next, loop, "boot-two")
    second_id = second.id
    assert {:ok, %{program: ^second_id}} = Tape.turn(ctx, next.id)
    assert {:ok, %{program: %{row: ^second_id, epoch: epoch}}} = build(ctx, next)
    assert epoch == second.epoch
    assert Scripted.sessions(fake, theirs.id) == %{}
  end

  # ---------------------------------------------------------------------------
  # Rows, turns and the driver

  defp row!(ctx) do
    {:ok, row} =
      McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json:
          Jason.encode!(%{
            "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
            "env" => %{}
          })
      })

    row
  end

  # The person's post to the member in its own thread; nothing is pinned
  # before the loop builds the turn.
  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "coder", requested_by: ctx.user_id}
      })

    assert turn.program == nil
    turn
  end

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  # The driver of `row` opens, starts, takes the turn's work and its post,
  # and answers it with an idle: the turn completes.
  defp completed!(fake, row, turn, loop, boot) do
    assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 10_000
    assert home == row.id

    Prima.Test.Wait.wait_until(
      fn -> Enum.any?(Scripted.sessions(fake, row.id), fn {_id, s} -> s.running end) end,
      10_000,
      "the driver's session to stand"
    )

    say(fake, row, %{
      "t" => "hello",
      "v" => Opus.Brain.Wire.version(),
      "driver" => "cyfr-claude-code",
      "boot" => boot
    })

    assert %{"t" => "start"} = sent()
    say(fake, row, %{"t" => "started", "session" => @session, "fresh" => true, "held" => []})
    assert %{"t" => "work", "id" => work} = sent()
    say(fake, row, %{"t" => "accepted", "id" => work})
    assert %{"t" => "post", "id" => post} = sent()
    say(fake, row, %{"t" => "accepted", "id" => post})

    say(fake, row, %{
      "t" => "idle",
      "gen" => 0,
      "work" => turn.id,
      "answered" => [post],
      "stop" => "end_turn"
    })

    assert :completed = Task.await(loop, 30_000)
  end

  defp say(fake, row, event), do: Scripted.write(fake, row.id, Jason.encode!(event))

  defp sent(timeout \\ 10_000) do
    assert_receive {:session, "send", %{"lines" => [line]}, _fields}, timeout
    Jason.decode!(line)
  end

  # The turn built again as a resumed loop builds it: from its row, under
  # the authority it pinned.
  defp build(ctx, turn) do
    {:ok, turn} = Tape.turn(ctx, turn.id)

    {:ok, authority} =
      Opus.authority_for(ctx, {:id, turn.profile_id}, Prima.AgentRef.soul_ref(),
        budget_id: turn.budget_id
      )

    Aqua.Loop.Turn.build(ctx, turn, authority: authority, excerpt?: false)
  end
end
