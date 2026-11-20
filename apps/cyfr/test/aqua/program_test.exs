# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramTest do
  @moduledoc """
  A program used as a brain through the real loop and the real attendant
  (`Aqua.Program`), the test playing the brain's driver against the
  scripted backends service as `Opus.BrainTest` does.

  A turn on a program brain opens with the host's `program.start` of the
  brain's row, which asks nothing, a schedule's turn's too: the driver is
  given its start in the configuration the turn's mode sets, the turn's
  work and the turn's post. What the program is given first joins the
  turn's read threads before its start runs, and a post that carries
  another thread's posts is written at once and joins those threads as it
  is written. What the program says is a post of Aqua's, its
  usage is counted once, and the turn completes on the `idle` that answers
  every post it was given, one written while the program starts, works or
  waits on an ask's call included, each after the post that opened the
  turn. Its asks are steps the loop decides under the member's mode and
  runs, answered with their results: auto runs an offered one, and
  read-only refuses one that does more than read in the read-only
  sentence, which the thread is told once, and runs a read; an ask of a
  tool the turn does not offer is refused, and one of other work writes no
  step and closes the session. A post and an answer owed together are
  written one at a time, the answer first. A session left from the turn
  before takes the next turn's work, and new startup options restart the
  driver, resuming. A holder's end resumes the native session with the
  posts whose delivery its transcript says: one it holds is continued by
  one notice, one it does not ends the turn, and an answer the resumed
  session no longer asks for comes as one notice that names its call,
  attempted once. A transcript the harness no longer has starts over, the
  thread its context, and in the middle of the work one prompt carries
  what its calls answered. Stop closes the session first, during a CYFR
  tool too. A program turn has no deadline, and the program's own silence
  ends it, never while an ask's call runs.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted

  @root :crypto.strong_rand_bytes(32)
  @session "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
  @title "Aqua"

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
    {:ok, ctx: ctx, fake: fake, thread: thread, row: brain_row!(ctx)}
  end

  describe "a turn on a program brain" do
    test "opens with the host's start, which asks nothing, and completes on the idle that answers its post",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "what is in notes.md?")
      loop = run(ctx, turn)

      %{start: start, work: work} = started!(fake, row)
      spec = spec!(ctx, turn)
      start_step = start_step(ctx, turn)

      # The holder sets `read_only` from the turn's mode, auto here.
      assert Map.delete(start, "system") == %{
               "t" => "start",
               "gen" => 0,
               "config" => %{"model" => spec.agent["model"], "read_only" => false}
             }

      assert without_clock(start["system"]) == without_clock(spec.system)

      assert work == %{
               "t" => "work",
               "id" => start_step.id,
               "work" => turn.id,
               "tools" => json(spec.tools)
             }

      post = sent()
      [input] = inputs(ctx, turn)
      assert post == posted(input, turn, "what is in notes.md?")
      say(fake, row, accepted(input))
      say(fake, row, said(turn, "msg_1", "notes.md holds three lines."))
      say(fake, row, usage(turn, "result-1"))
      committed!(ctx, thread, 6)
      # The same result handed again in a batch of its own counts nothing.
      say(fake, row, usage(turn, "result-1"))
      committed!(ctx, thread, 7)
      say(fake, row, idle(turn, [input.id]))

      assert :completed = Task.await(loop, 30_000)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)

      # The start was the host's, run with nothing asked.
      assert step_fields(start_step(ctx, turn)) == %{
               kind: "tool",
               purpose: "brain",
               tool: "program",
               action: "start",
               dispatch_state: "closed",
               outcome: "ok",
               idempotency_key: TurnStorage.brain_start_key(turn.id),
               message_id: start_step.message_id,
               usage: %{
                 "models" => %{"m" => counts()},
                 "results" => 1,
                 "partial" => 0,
                 "unknown" => 0
               }
             }

      assert call_row(ctx, start_step) ==
               {"tool_call", "program",
                %{
                  "tool_call_id" => "start",
                  "name" => "program",
                  "tool" => "program",
                  "action" => "start",
                  "arguments" => %{"action" => "start", "program" => row.id, "epoch" => row.epoch},
                  "kind" => "execute"
                }}

      # The post was carried by its input step, which its idle answered.
      assert [carried] = inputs(ctx, turn)
      assert step_fields(carried) == input_fields("post", turn.message_id, "ok")
      assert carried_by(ctx, turn.message_id) == input.id

      # What the program said is a post of Aqua's in the thread.
      assert said_rows(ctx, thread, turn) == [
               {Arca.Schemas.Message.agent_author(), "aqua", "text",
                "notes.md holds three lines.", %{"brain_message" => "msg_1"}}
             ]
    end

    test "takes a post written while the program works at once, and completes only on the idle that answers it too",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      started!(fake, row)
      _first = sent()
      [first] = inputs(ctx, turn)
      say(fake, row, accepted(first))
      committed!(ctx, thread, 4)

      {:ok, %{message: steer}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "and this"},
          steer_turn_id: turn.id
        })

      second_post = sent()
      [_first, second] = inputs(ctx, turn)
      assert second_post == posted(second, turn, "and this")
      assert step_fields(second) == input_fields("post", steer.id, nil)
      assert carried_by(ctx, steer.id) == second.id
      say(fake, row, accepted(second))

      # The idle that answers the first post alone leaves the turn running.
      say(fake, row, idle(turn, [first.id]))
      committed!(ctx, thread, 6)
      assert Task.yield(loop, 1_000) == nil
      assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)

      say(fake, row, idle(turn, [second.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok")
             ]
    end
  end

  describe "a post's files" do
    test "reach the program after the post's text, in order: an image and a PDF as " <>
           "themselves, a text file as text, any other named as attached and not readable",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      {id, refs} =
        stored!(ctx, thread, [
          %{"filename" => "moon.png", "media_type" => "image/png", "bytes" => "PNG"},
          %{"filename" => "brief.pdf", "media_type" => "application/pdf", "bytes" => "%PDF-1"},
          %{"filename" => "notes.txt", "media_type" => "text/plain", "bytes" => "three lines"},
          %{"filename" => "tool.bin", "media_type" => "application/octet-stream", "bytes" => "\0"}
        ])

      turn = accept!(ctx, thread, row, "look at these", %{"attachments" => refs}, id)
      loop = run(ctx, turn)
      started!(fake, row)

      post = sent()
      [input] = inputs(ctx, turn)

      assert post ==
               posted(input, turn, "look at these", [
                 %{
                   "type" => "image",
                   "media_type" => "image/png",
                   "data" => Base.encode64("PNG")
                 },
                 %{
                   "type" => "document",
                   "media_type" => "application/pdf",
                   "data" => Base.encode64("%PDF-1")
                 },
                 %{"type" => "text", "text" => "The attached file notes.txt:\n\nthree lines"},
                 %{
                   "type" => "text",
                   "text" =>
                     "The file tool.bin (application/octet-stream) is attached, and this brain " <>
                       "cannot read it."
                 }
               ])

      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "a file whose block would take the line past the wire's bound is named as too large, " <>
           "and the post goes with the rest; one whose bytes are gone is left out",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      # Its base64 alone is past the line's 1 MiB.
      big = :binary.copy("P", 800_000)

      {id, refs} =
        stored!(ctx, thread, [
          %{"filename" => "big.png", "media_type" => "image/png", "bytes" => big},
          %{"filename" => "gone.png", "media_type" => "image/png", "bytes" => "GONE"},
          %{"filename" => "small.png", "media_type" => "image/png", "bytes" => "PNG"}
        ])

      [_big, gone, _small] = refs

      {:ok, _} =
        Arca.Files.delete(
          Sanctum.Context.actor(ctx),
          "threads/#{thread.id}/#{id}/#{gone["stored_name"]}"
        )

      turn = accept!(ctx, thread, row, "three images", %{"attachments" => refs}, id)
      loop = run(ctx, turn)
      started!(fake, row)

      post = sent()
      [input] = inputs(ctx, turn)

      assert post ==
               posted(input, turn, "three images", [
                 %{
                   "type" => "text",
                   "text" =>
                     "The file big.png (image/png) is attached, and it is too large to hand to " <>
                       "this program."
                 },
                 %{"type" => "image", "media_type" => "image/png", "data" => Base.encode64("PNG")}
               ])

      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "a post written while the program works carries its files as the first post does",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      started!(fake, row)
      _first = sent()
      [first] = inputs(ctx, turn)
      say(fake, row, accepted(first))
      committed!(ctx, thread, 4)

      {id, refs} =
        stored!(ctx, thread, [
          %{"filename" => "moon.webp", "media_type" => "image/webp", "bytes" => "WEBP"}
        ])

      steer!(ctx, thread, turn, "and this one", %{"attachments" => refs}, id)

      post = sent()
      [_first, second] = inputs(ctx, turn)

      assert post ==
               posted(second, turn, "and this one", [
                 %{
                   "type" => "image",
                   "media_type" => "image/webp",
                   "data" => Base.encode64("WEBP")
                 }
               ])

      say(fake, row, accepted(second))
      say(fake, row, idle(turn, [first.id, second.id]))
      assert :completed = Task.await(loop, 30_000)
    end
  end

  describe "what the program writes as it works" do
    test "its text of the open work streams to the thread's viewers as it is written, under " <>
           "the turn's fence: its said row settles it, and a message no row lands is withdrawn " <>
           "at the native turn's end",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      watch!(ctx, thread)
      turn = accept!(ctx, thread, row, "what is in notes.md?")
      loop = run(ctx, turn)
      assert_receive %Cyfr.Bus.ThreadEvent{kind: :turn_fence, data: announced}, 10_000
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      {:ok, %{fence: fence}} = Tape.turn(ctx, turn.id)

      # The fence a viewer keeps the streamed text under is announced.
      assert announced == %{turn_id: turn.id, fence: fence}

      say(fake, row, accepted(input))
      say(fake, row, text(turn, "msg_1", "notes.md "))
      say(fake, row, text(turn, "msg_1", "holds three lines."))
      first = delta!()
      second = delta!()

      assert [first, second] == [
               streamed(turn, fence, "msg_1", 0, {0, 5}, "notes.md "),
               streamed(turn, fence, "msg_1", 0, {0, 6}, "holds three lines.")
             ]

      viewer = Aqua.Loop.Stream.new() |> Aqua.Loop.Stream.advance(fence)
      viewer = viewer |> Aqua.Loop.Stream.add(first) |> Aqua.Loop.Stream.add(second)

      assert Aqua.Loop.Stream.texts(viewer) == [
               %{step_id: "msg_1", role: nil, text: "notes.md holds three lines."}
             ]

      say(fake, row, said(turn, "msg_1", "notes.md holds three lines."))

      assert_receive %Cyfr.Bus.ThreadEvent{
                       kind: :message,
                       data: %{kind: "text", sent_by: "aqua"} = landed
                     },
                     10_000

      assert Aqua.Loop.Stream.texts(Aqua.Loop.Stream.landed(viewer, landed)) == []

      say(fake, row, text(turn, "msg_2", "and then"))
      assert delta!() == streamed(turn, fence, "msg_2", 1, {0, 8}, "and then")
      say(fake, row, idle(turn, [input.id]))

      assert_receive %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned, data: abandoned}, 10_000
      assert abandoned == marker(turn, fence, "msg_2", 1)
      assert :completed = Task.await(loop, 30_000)
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta}
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned}
    end

    test "text that lands no row is withdrawn when Stop closes the session",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      watch!(ctx, thread)
      turn = accept!(ctx, thread, row, "work on it")
      tasks = start_supervised!(Task.Supervisor)

      loop =
        Task.Supervisor.async_nolink(tasks, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, text(turn, "msg_1", "Starting"))
      {:ok, open} = Tape.turn(ctx, turn.id)
      assert delta!() == streamed(turn, open.fence, "msg_1", 0, {0, 5}, "Starting")

      stop = fn ->
        monitor = Process.monitor(loop.pid)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          10_000 -> :ok
        end
      end

      assert {:ok, aborted} = Aqua.Loop.abort(ctx, open, "stopped", stop)
      assert_receive %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned, data: abandoned}, 10_000
      assert abandoned == marker(turn, open.fence, "msg_1", 0)
      {:ok, _} = Tape.finish(ctx, aborted, "cancelled", %{error: "stopped"})
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned}
    end

    test "text that lands no row is withdrawn when the turn fails",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      watch!(ctx, thread)
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, text(turn, "msg_1", "Starting"))
      {:ok, %{fence: fence}} = Tape.turn(ctx, turn.id)
      assert delta!() == streamed(turn, fence, "msg_1", 0, {0, 5}, "Starting")

      say(fake, row, %{
        "t" => "error",
        "gen" => 0,
        "work" => turn.id,
        "type" => "provider_error",
        "message" => "The provider failed."
      })

      line = "#{@title} could not answer: The provider failed."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert_receive %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned, data: abandoned}, 10_000
      assert abandoned == marker(turn, fence, "msg_1", 0)
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned}
    end

    test "text of other work, or of none, is not streamed",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      watch!(ctx, thread)
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, text(turn, "msg_other", "for other work", "trn_other"))
      say(fake, row, text(turn, "msg_none", "for no work", :none))
      say(fake, row, text(turn, "msg_1", "mine"))
      {:ok, %{fence: fence}} = Tape.turn(ctx, turn.id)

      # One process announces in order, so the first delta is the first
      # one announced.
      assert delta!() == streamed(turn, fence, "msg_1", 0, {0, 7}, "mine")
      say(fake, row, said(turn, "msg_1", "mine"))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta}
      refute_received %Cyfr.Bus.ThreadEvent{kind: :delta_abandoned}
    end
  end

  describe "the program's asks" do
    test "an ask of the open turn is a step the loop decides and runs, answered with its result; one of a tool not offered is refused",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "list the programs")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      offered = Enum.map(spec!(ctx, turn).tools, & &1["name"])
      assert "program" in offered
      refute "vault" in offered

      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      answer = sent()
      listed = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1"))
      {:ok, result} = Tape.message(ctx, listed.result_message_id)
      [_post, answered] = inputs(ctx, turn)

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-1",
               "content" => result.content,
               "is_error" => false
             }

      assert Map.take(listed, [:kind, :purpose, :tool, :action, :dispatch_state, :outcome]) == %{
               kind: "tool",
               purpose: "brain",
               tool: "program",
               action: "list",
               dispatch_state: "closed",
               outcome: "ok"
             }

      assert call_row(ctx, listed) ==
               {"tool_call", "program",
                %{
                  "tool_call_id" => "ask-1",
                  "name" => "program",
                  "tool" => "program",
                  "action" => "list",
                  "arguments" => %{"action" => "list"},
                  "kind" => "read"
                }}

      say(fake, row, accepted(answered))

      say(fake, row, ask(turn, "ask-2", "vault", %{"action" => "list"}))
      refused = sent()
      denied = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-2"))
      {:ok, denial} = Tape.message(ctx, denied.result_message_id)
      [_post, _answered, told] = inputs(ctx, turn)

      assert refused == %{
               "t" => "answer",
               "id" => told.id,
               "ask" => "ask-2",
               "content" => denial.content,
               "is_error" => true
             }

      assert {denied.dispatch_state, denied.outcome, denied.error} ==
               {"closed", "denied", "vault is not one of the tools this work has"}

      say(fake, row, accepted(told))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)

      {:ok, steps} = Tape.steps(ctx, turn)

      assert Enum.map(steps, & &1.idempotency_key) == [
               TurnStorage.brain_start_key(turn.id),
               "0:post:#{turn.message_id}",
               TurnStorage.brain_ask_key(turn.id, "ask-1"),
               "0:answer:#{result.id}",
               TurnStorage.brain_ask_key(turn.id, "ask-2"),
               "0:answer:#{denial.id}"
             ]

      refute_received {:session, "send", _wire, _fields}
    end

    test "an ask of other work, or of none, writes no step and cannot be answered here, so the " <>
           "session closes and the turn ends saying why",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      # Each round is a driver process of its own, its boot its own.
      for {work, boot} <- [{"trn_other", "boot-one"}, {nil, "boot-two"}] do
        turn = accept!(ctx, thread, row, "first")
        loop = run(ctx, turn)
        started!(fake, row, boot)
        _post = sent()
        [input] = inputs(ctx, turn)
        say(fake, row, accepted(input))

        foreign = ask(turn, "foreign-ask", "program", %{"action" => "list"}, work)
        say(fake, row, if(work, do: foreign, else: Map.delete(foreign, "work")))

        line = "#{@title} asked for a tool for other work than this, so it was stopped."
        assert {:failed, ^line} = Task.await(loop, 15_000)
        assert system_lines(ctx, thread, turn) == [line]
        assert_receive {:session, "close", _wire, _fields}, 10_000
        assert running_sessions(fake, row) == []
        assert step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "foreign-ask")) == nil

        assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
                 input_fields("post", turn.message_id, "ok")
               ]

        refute_received {:session, "send", _wire, _fields}
      end
    end

    test "a post and a tool's answer owed together are written one at a time, the answer " <>
           "first, each once",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      started!(fake, row)
      _first = sent()
      [first] = inputs(ctx, turn)
      say(fake, row, accepted(first))
      committed!(ctx, thread, 4)

      # A post is written and not yet taken when the program asks.
      steer = steer!(ctx, thread, turn, "and this")
      second_post = sent()
      [_first, second] = inputs(ctx, turn)
      assert second_post == posted(second, turn, "and this")
      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      listed = closed!(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1"))
      {:ok, result} = Tape.message(ctx, listed.result_message_id)

      # The answer and a later post both wait on the post the driver has
      # not taken: nothing is written meanwhile.
      later = steer!(ctx, thread, turn, "one more")
      refute_receive {:session, "send", _wire, _fields}, 500

      say(fake, row, accepted(second))
      answer = sent()
      [_first, _second, answered] = inputs(ctx, turn)

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-1",
               "content" => result.content,
               "is_error" => false
             }

      refute_receive {:session, "send", _wire, _fields}, 500
      say(fake, row, accepted(answered))
      third_post = sent()
      [_first, _second, _answered, third] = inputs(ctx, turn)
      assert third_post == posted(third, turn, "one more")
      say(fake, row, accepted(third))
      say(fake, row, idle(turn, [first.id, second.id, third.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok"),
               input_fields("answer", result.id, "ok"),
               input_fields("post", later.id, "ok")
             ]

      refute_received {:session, "send", _wire, _fields}
    end

    test "a post written while an ask's call runs is written at once, and the ask's answer " <>
           "follows",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "run it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      # The program asks for a call that does more than read, which auto
      # runs at once; its terminal's open is held, so it runs on.
      opening = held_start!(fake, row, turn, "ask-1")
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")

      steer = steer!(ctx, thread, turn, "and this")
      post = sent()
      [_input, steered] = inputs(ctx, turn)
      assert post == posted(steered, turn, "and this")
      say(fake, row, accepted(steered))
      closed!(ctx, turn, steered.idempotency_key)

      # The call still runs, and the turn with it.
      assert Map.take(step_by_key(ctx, turn, key), [:dispatch_state, :outcome]) ==
               %{dispatch_state: "dispatched", outcome: nil}

      assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)

      send(opening, :go)
      answer = sent()
      written = step_by_key(ctx, turn, key)
      {:ok, result} = Tape.message(ctx, written.result_message_id)
      [_input, _steered, answered] = inputs(ctx, turn)

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-1",
               "content" => result.content,
               "is_error" => false
             }

      assert Map.take(written, [:tool, :action, :dispatch_state, :outcome]) ==
               %{
                 tool: "program",
                 action: "start",
                 dispatch_state: "closed",
                 outcome: "ok"
               }

      say(fake, row, accepted(answered))
      say(fake, row, idle(turn, [input.id, steered.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok"),
               input_fields("answer", result.id, "ok")
             ]

      refute_received {:session, "send", _wire, _fields}
    end

    test "asks made while the turn is paused around a launch are recorded and dispatched by " <>
           "none, and are decided by the mode when the turn goes on",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      app = quiet_app!(ctx)

      start_supervised!(
        {Cyfr.Test.ScriptedWorker,
         ref: [app], script: [{:hold, self()}, {:output, %{"ran" => true}}]}
      )

      turn = accept!(ctx, thread, row, "run the app, then tidy up")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      # The program launches the app, whose run is held: the turn is
      # paused around it.
      launch = %{"action" => "run", "reference" => app <> ":1.0.0", "input" => %{}}
      say(fake, row, ask(turn, "ask-1", "execution", launch))
      assert_receive {:scripted_probe, launched, _child}, 60_000
      assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, turn.id)

      # While it is paused the program asks for a write and a read: each
      # recorded, neither run.
      keep = %{"action" => "keep", "name" => "todo", "content" => "tidy"}
      say(fake, row, ask(turn, "ask-2", "notes", keep))
      say(fake, row, ask(turn, "ask-3", "program", %{"action" => "list"}))
      committed!(ctx, thread, 7)
      keys = for ask <- ~w(ask-1 ask-2 ask-3), do: TurnStorage.brain_ask_key(turn.id, ask)

      for key <- tl(keys) do
        assert Map.take(step_by_key(ctx, turn, key), [:dispatch_state, :outcome, :started_at]) ==
                 %{dispatch_state: "proposed", outcome: nil, started_at: nil}
      end

      assert {:ok, %{status: "paused", paused_reason: "launch"}} = Tape.turn(ctx, turn.id)

      # The launch ends and the turn goes on: auto runs both, each started
      # once the launch had closed, and each ask is answered once, in order.
      send(launched, :continue)
      answers = for _ask <- keys, do: accept_next!(fake, row)
      [ran, kept, listed] = steps = Enum.map(keys, &step_by_key(ctx, turn, &1))
      [_input | answered] = inputs(ctx, turn)

      owed =
        for {{step, ask}, input} <- Enum.zip(Enum.zip(steps, ~w(ask-1 ask-2 ask-3)), answered) do
          {:ok, result} = Tape.message(ctx, step.result_message_id)

          %{
            "t" => "answer",
            "id" => input.id,
            "ask" => ask,
            "content" => result.content,
            "is_error" => false
          }
        end

      assert answers == owed

      assert Enum.map(steps, &Map.take(&1, [:kind, :tool, :action, :dispatch_state, :outcome])) ==
               [
                 %{
                   kind: "launch",
                   tool: "execution",
                   action: "run",
                   dispatch_state: "closed",
                   outcome: "ok"
                 },
                 %{
                   kind: "tool",
                   tool: "notes",
                   action: "keep",
                   dispatch_state: "closed",
                   outcome: "ok"
                 },
                 %{
                   kind: "tool",
                   tool: "program",
                   action: "list",
                   dispatch_state: "closed",
                   outcome: "ok"
                 }
               ]

      for step <- [kept, listed],
          do: assert(DateTime.compare(step.started_at, ran.ended_at) != :lt)

      assert {:ok, %{content: "tidy"}} = Aqua.Notes.read(ctx, "todo")
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      refute_received {:session, "send", _wire, _fields}
    end

    test "a read-only member's asks that do more than read are refused in the read-only " <>
           "sentence, which the thread is told once, and its read runs",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      read_only!(ctx)
      turn = accept!(ctx, thread, row, "tidy up")
      loop = run(ctx, turn)
      %{start: start} = started!(fake, row)

      # The holder starts the program read-only.
      assert start["config"] == %{"model" => spec!(ctx, turn).agent["model"], "read_only" => true}

      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      said =
        "#{@title} is read-only, so it refused a step that does more than read. To let it, " <>
          "switch #{@title} to auto on the Aqua page."

      # Two offered asks that do more than read, the start auto runs in the
      # tests above among them: each refused in the sentence, as an error.
      for {id, name, args} <- [
            {"ask-1", "program", start_args(row)},
            {"ask-2", "files", %{"action" => "write", "path" => "data/a.md", "content" => "x"}}
          ] do
        say(fake, row, ask(turn, id, name, args))
        refused = sent()
        denied = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, id))
        {:ok, denial} = Tape.message(ctx, denied.result_message_id)
        told = List.last(inputs(ctx, turn))

        assert refused == %{
                 "t" => "answer",
                 "id" => told.id,
                 "ask" => id,
                 "content" => denial.content,
                 "is_error" => true
               }

        assert {denied.tool, denied.action, denied.dispatch_state, denied.outcome, denied.error} ==
                 {name, args["action"], "closed", "denied", said}

        say(fake, row, accepted(told))
      end

      # A read runs.
      say(fake, row, ask(turn, "ask-3", "program", %{"action" => "list"}))
      answer = sent()
      listed = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-3"))
      {:ok, result} = Tape.message(ctx, listed.result_message_id)
      answered = List.last(inputs(ctx, turn))

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-3",
               "content" => result.content,
               "is_error" => false
             }

      assert {listed.dispatch_state, listed.outcome} == {"closed", "ok"}
      say(fake, row, accepted(answered))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)

      # The thread was told once, and the refused start opened nothing.
      assert system_lines(ctx, thread, turn) == [said]
      refute_received {:session, "open", %{"mode" => "terminal"}, _fields}
      refute_received {:session, "send", _wire, _fields}
    end
  end

  describe "its start's decision" do
    test "a post written while the harness starts skips nothing: it is written once the work " <>
           "is taken, after the post that opened the turn",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "hello")
      loop = run(ctx, turn)
      opened!(fake, row, "boot-one")
      assert %{"t" => "start"} = sent()
      steer = steer!(ctx, thread, turn, "and this")

      # Nothing of the turn's posts is written before the harness stands
      # and takes the work.
      refute_receive {:session, "send", _wire, _fields}, 1_000
      say(fake, row, started([]))
      work = sent()

      assert work == %{
               "t" => "work",
               "id" => start_step(ctx, turn).id,
               "work" => turn.id,
               "tools" => json(spec!(ctx, turn).tools)
             }

      assert inputs(ctx, turn) == []
      assert carried_by(ctx, steer.id) == nil

      say(fake, row, %{"t" => "accepted", "id" => work["id"]})
      first = sent()
      [opening] = inputs(ctx, turn)
      assert first == posted(opening, turn, "hello")
      say(fake, row, accepted(opening))
      second = sent()
      [_opening, steered] = inputs(ctx, turn)
      assert second == posted(steered, turn, "and this")
      say(fake, row, accepted(steered))
      say(fake, row, idle(turn, [opening.id, steered.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Map.take(start_step(ctx, turn), [:dispatch_state, :outcome]) ==
               %{dispatch_state: "closed", outcome: "ok"}

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok")
             ]

      assert system_lines(ctx, thread, turn) == []
    end

    test "a post that carries another thread's posts is written at once, and the threads it " <>
           "carries join the turn as it is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      steer =
        steer!(ctx, thread, turn, "and this brief", %{"attachments" => [brief("thr_news")]})

      post = sent()
      [_input, steered] = inputs(ctx, turn)
      assert post == posted(steered, turn, "and this brief")
      assert carried_by(ctx, steer.id) == steered.id
      {:ok, writing} = Tape.turn(ctx, turn.id)

      assert Arca.ThreadStorage.threads_of(writing.read_threads) == ["thr_news"]

      say(fake, row, accepted(steered))
      say(fake, row, idle(turn, [input.id, steered.id]))
      assert :completed = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == []

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok")
             ]

      refute_received {:session, "send", _wire, _fields}
    end

    test "a session left from the turn before takes the next turn's work, then its posts, one " <>
           "written before the work is taken among them, and opens nothing again",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      %{work: first_work} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      assert Aqua.Program.holding?(ctx.athanor_id, thread.id, "aqua")

      # The same session is given the next turn's work first.
      next = accept!(ctx, thread, row, "second")
      loop = run(ctx, next)
      work = sent()

      assert work == %{
               first_work
               | "id" => start_step(ctx, next).id,
                 "work" => next.id,
                 "tools" => json(spec!(ctx, next).tools)
             }

      # A post written before the work is taken is written nothing yet.
      steer = steer!(ctx, thread, next, "and this")
      refute_receive {:session, "send", _wire, _fields}, 1_000
      assert inputs(ctx, next) == []
      assert carried_by(ctx, next.message_id) == nil
      assert carried_by(ctx, steer.id) == nil

      say(fake, row, %{"t" => "accepted", "id" => work["id"]})
      post = sent()
      [second] = inputs(ctx, next)
      assert post == posted(second, next, "second")
      say(fake, row, accepted(second))
      post = sent()
      [_second, steered] = inputs(ctx, next)
      assert post == posted(steered, next, "and this")
      say(fake, row, accepted(steered))
      say(fake, row, idle(next, [second.id, steered.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, next), &step_fields/1) == [
               input_fields("post", next.message_id, "ok"),
               input_fields("post", steer.id, "ok")
             ]

      assert [_held] = running_sessions(fake, row)
      refute_received {:session, "open", _wire, _fields}
      refute_received {:session, "close", _wire, _fields}
      refute_received {:session, "send", _wire, _fields}
    end

    test "what the program is given first joins the turn before its start runs: the threads " <>
           "its post and the thread a fresh session reads carry, and its post carries the thread",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      # Its instructions carry a note, the thread an earlier post with a
      # file copied from another thread, and its own post another.
      {:ok, _} = Aqua.Notes.keep(ctx, "clip", "Fares rise on Monday")

      {:ok, _earlier} =
        Tape.append(ctx, thread.id, %{
          author: ctx.user_id,
          sent_by: "person",
          kind: "text",
          content: "from the wire",
          payload: %{"attachments" => [brief("thr_wire")]}
        })

      turn =
        accept!(ctx, thread, row, "read this brief", %{"attachments" => [brief("thr_post")]})

      loop = run(ctx, turn)
      opened!(fake, row, "boot-one")
      {:ok, starting} = Tape.turn(ctx, turn.id)

      assert Arca.ThreadStorage.threads_of(starting.read_threads) == ["thr_post", "thr_wire"]

      %{start: start} = begun!(fake, row)
      assert start["system"] =~ "Fares rise on Monday"
      post = sent()
      [input] = inputs(ctx, turn)
      person = Sanctum.Tenancy.Users.display_name(ctx.user_id)

      assert post ==
               Map.put(posted(input, turn, "read this brief"), "context", [
                 %{"type" => "text", "text" => "The thread so far:\n\n#{person}: from the wire"}
               ])

      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "every startup option the work names reaches the harness's start, none dropped",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "plan only")
      options!(turn, %{"permission_mode" => "plan", "effort" => "high"})
      loop = run(ctx, turn)
      %{start: start} = started!(fake, row)

      # Beside them the mode the holder sets: auto keeps the harness's own
      # permission mode.
      assert start["config"] == %{
               "model" => spec!(ctx, turn).agent["model"],
               "permission_mode" => "plan",
               "effort" => "high",
               "read_only" => false
             }

      post = sent()
      [input] = inputs(ctx, turn)
      assert post == posted(input, turn, "plan only")
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "a turn whose startup options differ from the running harness's closes its driver " <>
           "and starts a new one, resuming with them, before anything is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      %{start: first} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      assert Aqua.Program.holding?(ctx.athanor_id, thread.id, "aqua")

      next = accept!(ctx, thread, row, "second")
      options!(next, %{"effort" => "high"})
      loop = run(ctx, next)

      # The running harness started with other options: its process is
      # closed and a new one opened, with nothing written to either.
      assert_receive {:session, "close", _wire, _fields}, 10_000
      refute_received {:session, "send", _wire, _fields}
      opened!(fake, row, "boot-two")
      resume = sent()

      assert Map.delete(resume, "system") ==
               Map.merge(Map.delete(first, "system"), %{
                 "session" => @session,
                 "config" => %{
                   "model" => spec!(ctx, next).agent["model"],
                   "effort" => "high",
                   "read_only" => false
                 }
               })

      assert without_clock(resume["system"]) == without_clock(first["system"])
      say(fake, row, started([]))
      work = sent()

      assert work == %{
               "t" => "work",
               "id" => start_step(ctx, next).id,
               "work" => next.id,
               "tools" => json(spec!(ctx, next).tools)
             }

      say(fake, row, %{"t" => "accepted", "id" => work["id"]})
      post = sent()
      [second] = inputs(ctx, next)
      assert post == posted(second, next, "second")
      say(fake, row, accepted(second))
      say(fake, row, idle(next, [second.id]))
      assert :completed = Task.await(loop, 30_000)
      assert [_running] = running_sessions(fake, row)
      refute_received {:session, "open", _wire, _fields}
    end

    test "a startup option the harness does not take is refused before anything is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "warm")
      options!(turn, %{"temperature" => "0.2"})
      loop = run(ctx, turn)
      opened!(fake, row, "boot-one")

      line =
        "#{@title} could not start with what this work gives it: one of its options " <>
          "(model, temperature) or its instructions is not one it takes."

      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert {:ok, %{status: "failed", error: ^line}} = Tape.turn(ctx, turn.id)
      assert %{dispatch_state: "closed", error: ^line} = start_step(ctx, turn)
      assert_receive {:session, "close", _wire, _fields}, 10_000
      assert inputs(ctx, turn) == []
      refute_received {:session, "send", _wire, _fields}
    end

    test "a scheduled turn starts its program with nothing asked and runs as any turn of its mode",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      ctx = %{ctx | origin: :schedule}
      turn = accept!(ctx, thread, row, "hello")
      loop = run(ctx, turn)
      %{work: work} = started!(fake, row)
      assert work["id"] == start_step(ctx, turn).id
      post = sent()
      [input] = inputs(ctx, turn)
      assert post == posted(input, turn, "hello")
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)

      assert {:ok, %{status: "completed", origin: "schedule", error: nil}} =
               Tape.turn(ctx, turn.id)

      assert Map.take(start_step(ctx, turn), [:dispatch_state, :outcome, :error]) ==
               %{dispatch_state: "closed", outcome: "ok", error: nil}

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok")
             ]
    end
  end

  describe "recovery" do
    test "a holder's end resumes the native session naming the post, and a post its transcript holds is continued by one notice",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      %{start: first, work: work} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")
      resume = sent()

      assert resume ==
               Map.merge(first, %{"session" => @session, "pending" => [input.id]})

      say(fake, row, started([input.id]))
      assert sent() == work
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})

      notice = sent()
      [_post, noticed] = inputs(ctx, turn)

      assert notice ==
               posted(
                 noticed,
                 turn,
                 "CYFR restarted while you were working on the last message, which you " <>
                   "already have. Go on with it, or say where it stands."
               )

      assert step_fields(noticed) == input_fields("notice", turn.message_id, nil, "0:notice:")
      say(fake, row, accepted(noticed))
      say(fake, row, idle(turn, [noticed.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("notice", turn.message_id, "ok", "0:notice:")
             ]
    end

    test "a notice the holder refuses before writing it leaves its post owed: the next start " <>
           "names the post again, and the notice follows once",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      %{work: work} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)
      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")
      _resume = sent()
      say(fake, row, started([input.id]))
      assert sent() == work

      # The backend lost the process before this send: its unknown_session
      # says none of the notice was written.
      Scripted.refuse_once(fake, "send", "unknown_session")
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})
      assert %{"t" => "post"} = sent()
      opened!(fake, row, "boot-three")
      assert %{"t" => "start", "pending" => [pending]} = sent()
      assert pending == input.id
      assert [_input] = inputs(ctx, turn)

      say(fake, row, started([input.id]))
      assert sent() == work
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})
      notice = sent()
      [_post, noticed] = inputs(ctx, turn)
      assert notice["id"] == noticed.id
      say(fake, row, accepted(noticed))
      say(fake, row, idle(turn, [noticed.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("notice", turn.message_id, "ok", "0:notice:")
             ]
    end

    test "a post the resumed transcript does not hold ends the turn saying so, and is never written again",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      %{start: first} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")
      assert sent() == Map.merge(first, %{"session" => @session, "pending" => [input.id]})
      say(fake, row, started([]))

      line =
        "#{@title} was interrupted after it was handed your last message, and it is not " <>
          "handed that message again. Send a message to go on."

      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert {:ok, %{status: "failed", error: ^line}} = Tape.turn(ctx, turn.id)
      assert system_lines(ctx, thread, turn) == [line]

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok")
             ]

      assert {:ok, []} = Tape.brain_posts(ctx, turn)
      refute_received {:session, "send", _wire, _fields}
    end

    test "the driver's death with a tool's answer held back by a post resumes each held post " <>
           "with one notice, and the answer as one notice that names its call",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      %{start: first_start, work: work} = started!(fake, row)
      _post = sent()
      [first] = inputs(ctx, turn)
      say(fake, row, accepted(first))
      committed!(ctx, thread, 4)

      steer = steer!(ctx, thread, turn, "and this")
      steered_post = sent()
      [_first, steered] = inputs(ctx, turn)
      assert steered_post == posted(steered, turn, "and this")

      # The program asks while the post is not yet taken: the ask runs,
      # and its answer waits behind the post.
      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")
      listed = closed!(ctx, turn, key)
      {:ok, result} = Tape.message(ctx, listed.result_message_id)
      refute_receive {:session, "send", _wire, _fields}, 500

      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")

      assert sent() ==
               Map.merge(first_start, %{
                 "session" => @session,
                 "pending" => [first.id, steered.id]
               })

      say(fake, row, started([first.id, steered.id]))
      assert sent() == work
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})

      held = for _ <- 1..2, do: accept_next!(fake, row)
      [_first, _steered, noticed_first, noticed_steer] = inputs(ctx, turn)

      assert held == [
               posted(noticed_first, turn, post_notice()),
               posted(noticed_steer, turn, post_notice())
             ]

      # The resumed session does not hold the ask: its answer comes as one
      # notice naming the call, and no answer step is left of it.
      told = accept_next!(fake, row)
      [_first, _steered, _noticed_first, _noticed_steer, noticed_answer] = inputs(ctx, turn)

      assert told ==
               posted(noticed_answer, turn, answer_notice("program", "ask-1", result.content))

      say(fake, row, idle(turn, [noticed_first.id, noticed_steer.id, noticed_answer.id]))
      assert :completed = Task.await(loop, 30_000)

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok"),
               input_fields("notice", turn.message_id, "ok", "0:notice:"),
               input_fields("notice", steer.id, "ok", "0:notice:"),
               input_fields("notice", result.id, "ok", "0:notice:")
             ]

      # The call ran once: one step, one result, never dispatched again.
      {:ok, steps} = Tape.steps(ctx, turn)
      assert Enum.count(steps, &(&1.kind != "input" and &1.action == "list")) == 1
      assert step_by_key(ctx, turn, key) == listed
      assert result_rows(ctx, turn) == [start_step(ctx, turn).result_message_id, result.id]
      refute_received {:session, "send", _wire, _fields}
    end

    test "an answer whose delivery is uncertain becomes one notice, a second restart sends no " <>
           "second one and ends the turn saying so, and the call never runs again",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      %{start: first_start, work: work} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      answer = sent()
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")
      listed = step_by_key(ctx, turn, key)
      {:ok, result} = Tape.message(ctx, listed.result_message_id)
      [_post, answered] = inputs(ctx, turn)

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-1",
               "content" => result.content,
               "is_error" => false
             }

      # The answer was written and never taken when the driver ends: the
      # attendant commits the program's next line only once its write of
      # the answer has returned.
      say(fake, row, said(turn, "msg_1", "looking"))
      committed!(ctx, thread, 6)
      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")
      assert sent() == Map.merge(first_start, %{"session" => @session, "pending" => [input.id]})
      say(fake, row, started([input.id]))
      assert sent() == work
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})

      continued = accept_next!(fake, row)
      [_post, _answered, noticed_post] = inputs(ctx, turn)
      assert continued == posted(noticed_post, turn, post_notice())
      told = accept_next!(fake, row)
      [_post, _answered, _noticed_post, noticed_answer] = inputs(ctx, turn)

      assert told ==
               posted(noticed_answer, turn, answer_notice("program", "ask-1", result.content))

      closed!(ctx, turn, noticed_answer.idempotency_key)

      # The driver ends again before the program answers: the transcript
      # holds both notices, and neither is followed by another.
      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-three")

      assert sent() ==
               Map.merge(first_start, %{
                 "session" => @session,
                 "pending" => [noticed_post.id, noticed_answer.id]
               })

      say(fake, row, started([noticed_post.id, noticed_answer.id]))

      line =
        "#{@title} was interrupted after it was handed your last message, and it is not " <>
          "handed that message again. Send a message to go on."

      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == [line]

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("answer", result.id, "uncertain"),
               input_fields("notice", turn.message_id, "ok", "0:notice:"),
               input_fields("notice", result.id, "ok", "0:notice:")
             ]

      {:ok, steps} = Tape.steps(ctx, turn)
      assert Enum.count(steps, &(&1.kind != "input" and &1.action == "list")) == 1

      assert Map.take(step_by_key(ctx, turn, key), [:dispatch_state, :outcome, :result_message_id]) ==
               %{dispatch_state: "closed", outcome: "ok", result_message_id: result.id}

      assert result_rows(ctx, turn) == [start_step(ctx, turn).result_message_id, result.id]
      refute_receive {:session, "send", _wire, _fields}, 500
    end

    test "a transcript the harness no longer has starts over, and the next post carries the thread as its context",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      %{start: first} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, said(turn, "msg_1", "reply one"))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)

      # The driver ends between the thread's turns.
      Scripted.end_sessions(fake, row.id)

      Prima.Test.Wait.wait_until(
        fn -> not Aqua.Program.holding?(ctx.athanor_id, thread.id, "aqua") end,
        10_000,
        "the attendant to let its ended session go"
      )

      next = accept!(ctx, thread, row, "second")
      loop = run(ctx, next)
      opened!(fake, row, "boot-two")
      resume = sent()

      assert Map.delete(resume, "system") ==
               Map.merge(Map.delete(first, "system"), %{"session" => @session})

      say(fake, row, %{"t" => "gone"})

      fresh = sent()
      assert Map.delete(fresh, "system") == %{Map.delete(first, "system") | "gen" => 1}
      assert {:ok, %{generation: 1}} = Tape.brain(ctx, thread.id)

      assert system_lines(ctx, thread, next) == [
               "#{@title} no longer had its record of this thread, so it starts over from " <>
                 "the thread's posts."
             ]

      say(fake, row, started([]))
      assert %{"t" => "work"} = work = sent()
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})

      post = sent()
      [second] = inputs(ctx, next)
      person = Sanctum.Tenancy.Users.display_name(ctx.user_id)

      assert post ==
               Map.put(posted(second, next, "second"), "context", [
                 %{
                   "type" => "text",
                   "text" => "The thread so far:\n\n#{person}: first\n\n#{@title}: reply one"
                 }
               ])

      assert step_fields(second) == input_fields("post", next.message_id, nil, "1:post:")
      say(fake, row, %{"t" => "accepted", "id" => second.id})
      say(fake, row, %{idle(next, [second.id]) | "gen" => 1})
      assert :completed = Task.await(loop, 30_000)
    end

    test "a transcript lost in the middle of the work starts over with one prompt that carries " <>
           "the thread so far and what its calls answered, and runs none of them again",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "unfinished")
      loop = run(ctx, turn)
      %{start: first} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, said(turn, "msg_1", "looking"))
      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      answer = sent()
      listed = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1"))
      {:ok, result} = Tape.message(ctx, listed.result_message_id)
      say(fake, row, %{"t" => "accepted", "id" => answer["id"]})
      committed!(ctx, thread, 7)

      Scripted.end_sessions(fake, row.id)
      opened!(fake, row, "boot-two")
      assert sent() == Map.merge(first, %{"session" => @session, "pending" => [input.id]})
      say(fake, row, %{"t" => "gone"})
      fresh = sent()
      assert Map.delete(fresh, "system") == %{Map.delete(first, "system") | "gen" => 1}
      say(fake, row, started([]))
      assert %{"t" => "work"} = work = sent()
      say(fake, row, %{"t" => "accepted", "id" => work["id"]})

      prompt = sent()
      [_post, _answer, continued] = inputs(ctx, turn)
      person = Sanctum.Tenancy.Users.display_name(ctx.user_id)

      assert prompt ==
               Map.put(
                 posted(
                   continued,
                   turn,
                   "CYFR restarted and you no longer had your record of this thread, so the " <>
                     "thread so far is above, with what your calls in this work answered; they " <>
                     "are not run again. Go on with the last message, or say where it stands."
                 ),
                 "context",
                 [
                   %{
                     "type" => "text",
                     "text" =>
                       "The thread so far:\n\n#{person}: unfinished\n\n#{@title}: looking\n\n" <>
                         "Your call program answered: #{result.content}"
                   }
                 ]
               )

      assert step_fields(continued) ==
               input_fields("notice", turn.message_id, nil, "1:notice:")

      say(fake, row, accepted(continued))
      say(fake, row, %{idle(turn, [continued.id]) | "gen" => 1})
      assert :completed = Task.await(loop, 30_000)

      # The call ran once: one step, one result, never dispatched again.
      {:ok, steps} = Tape.steps(ctx, turn)
      assert Enum.count(steps, &(&1.kind != "input" and &1.action == "list")) == 1
      assert step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1")) == listed
    end
  end

  describe "its end" do
    test "Stop closes the session before anything of the turn stops, and the turn ends cancelled",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      tasks = start_supervised!(Task.Supervisor)

      loop =
        Task.Supervisor.async_nolink(tasks, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      Scripted.hold(fake, "close")
      {:ok, open} = Tape.turn(ctx, turn.id)

      # Closed on purpose, the session ends the loop's wait and the loop
      # ends by itself, its late writes refused by the moved fence. The
      # abort's stop waits for that end, so no process is stopped while
      # it holds the test's shared connection.
      stop = fn ->
        monitor = Process.monitor(loop.pid)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          10_000 -> :ok
        end
      end

      stopping = Task.async(fn -> Aqua.Loop.abort(ctx, open, "stopped", stop) end)

      # The session's close is under way and nothing of the turn has
      # stopped: its loop still runs, and the abort waits on the close.
      assert_receive {:held, "close", service}, 10_000
      assert Process.alive?(loop.pid)
      assert Task.yield(stopping, 500) == nil

      send(service, :go)
      assert {:ok, aborted} = Task.await(stopping, 30_000)
      assert_receive {:DOWN, _ref, :process, pid, _reason} when pid == loop.pid, 10_000
      assert running_sessions(fake, row) == []

      {:ok, _} = Tape.finish(ctx, aborted, "cancelled", %{error: "stopped"})
      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn.id)
      refute_received {:session, "send", _wire, _fields}
    end

    test "Stop while a CYFR tool the program asked for runs closes the session before " <>
           "anything of the turn stops, and the tool's step settles by its own record",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "run it")
      tasks = start_supervised!(Task.Supervisor)

      loop =
        Task.Supervisor.async_nolink(tasks, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      # The program asks to run its own row on a terminal, which auto
      # runs at once; the terminal's open is held.
      Scripted.hold(fake, "open", 30_000)
      args = %{"action" => "start", "program" => row.id, "epoch" => row.epoch}
      say(fake, row, ask(turn, "ask-1", "program", args))
      assert_receive {:held, "open", opening}, 10_000
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")
      assert %{dispatch_state: "dispatched"} = step_by_key(ctx, turn, key)
      assert {:ok, [%{by: :aqua}]} = Opus.Programs.running(ctx)

      Scripted.hold(fake, "close")
      {:ok, open} = Tape.turn(ctx, turn.id)
      stopping = Task.async(fn -> Aqua.Loop.abort(ctx, open, "stopped") end)

      # The session's close is under way while the tool still runs, and
      # nothing of the turn has stopped.
      assert_receive {:held, "close", closing}, 10_000
      assert Process.alive?(loop.pid)
      assert Task.yield(stopping, 500) == nil

      send(closing, :go)
      assert {:ok, aborted} = Task.await(stopping, 30_000)
      assert_receive {:DOWN, _ref, :process, pid, _reason} when pid == loop.pid, 10_000
      {:ok, _} = Tape.finish(ctx, aborted, "cancelled", %{error: "stopped"})
      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn.id)

      # The tool's step settles by its own record: a start whose effect
      # may have landed is marked uncertain.
      stopped = step_by_key(ctx, turn, key)

      assert Map.take(stopped, [
               :kind,
               :purpose,
               :tool,
               :action,
               :dispatch_state,
               :outcome,
               :error,
               :result_message_id,
               :usage
             ]) == %{
               kind: "tool",
               purpose: "brain",
               tool: "program",
               action: "start",
               dispatch_state: "uncertain",
               outcome: "uncertain",
               error: "stopped",
               result_message_id: nil,
               usage: nil
             }

      assert call_row(ctx, stopped) ==
               {"tool_call", "program",
                %{
                  "tool_call_id" => "ask-1",
                  "name" => "program",
                  "tool" => "program",
                  "action" => "start",
                  "arguments" => args,
                  "kind" => "execute"
                }}

      # Nothing of the row is held once the turn is over: its owner is
      # released, which ends every session of it on the service, and no
      # terminal of the turn is left when the held open answers late.
      assert_receive {:control, "release", %{"owners" => [%{"server" => server}]}, _fields},
                     10_000

      assert server == row.id
      send(opening, :go)
      assert_receive {:session, "open", %{"mode" => "terminal"}, _fields}, 10_000

      Prima.Test.Wait.wait_until(
        fn -> Opus.Programs.running(ctx) == {:ok, []} end,
        10_000,
        "the stopped turn's terminal to end"
      )

      refute_received {:session, "send", _wire, _fields}
    end

    test "a program turn has no deadline: one whose active time is past its turn's keeps running",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "take your time")

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [active_ms: 24 * 60 * 60 * 1000]
        )

      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, ask(turn, "ask-1", "program", %{"action" => "list"}))
      assert %{"t" => "answer"} = answer = sent()
      say(fake, row, %{"t" => "accepted", "id" => answer["id"]})
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "the program's own silence after it took a post ends its work, saying so",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      silence!(2_000)
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      line = "#{@title} said nothing for 0 minutes, so its work here ended."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == [line]
      assert_receive {:session, "close", _wire, _fields}, 10_000
      assert running_sessions(fake, row) == []
    end

    test "the silence runs on after an idle that answers only some of the posts the program took",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      silence!(1_000)
      turn = accept!(ctx, thread, row, "first")
      loop = run(ctx, turn)
      started!(fake, row)
      _first = sent()
      [first] = inputs(ctx, turn)
      say(fake, row, accepted(first))
      committed!(ctx, thread, 4)
      steer!(ctx, thread, turn, "second")
      _second = sent()
      [_first, second] = inputs(ctx, turn)
      say(fake, row, accepted(second))
      say(fake, row, idle(turn, [first.id]))

      line = "#{@title} said nothing for 0 minutes, so its work here ended."
      assert {:failed, ^line} = Task.await(loop, 15_000)
      assert system_lines(ctx, thread, turn) == [line]
    end

    test "an idle of other work leaves the open work owing output: after a tool's answer is " <>
           "taken with no post owed, the program is still busy and its clock runs",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "run it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      # While an ask's call runs, the program's idle answers the post.
      opening = held_start!(fake, row, turn, "ask-1")
      say(fake, row, idle(turn, [input.id]))
      committed!(ctx, thread, 6)
      send(opening, :go)
      assert %{"t" => "answer", "ask" => "ask-1", "id" => answer} = sent()
      say(fake, row, %{"t" => "accepted", "id" => answer})
      committed!(ctx, thread, 7)
      say(fake, row, idle(%{id: "previous-work"}, []))
      committed!(ctx, thread, 8)
      {:ok, %{progress: progress}} = TurnStorage.brain(Sanctum.Context.actor(ctx), thread.id)
      say(fake, row, idle(turn, []))
      assert :completed = Task.await(loop, 30_000)
      assert {progress["owed"], progress["busy"]} == {[], true}
      assert is_binary(progress["clock"]["since"])
    end

    test "an attendant that ends while its turn waits on it ends the turn, saying so",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      [{attendant, _}] =
        Registry.lookup(Aqua.Program.Registry, {ctx.athanor_id, thread.id, turn.agent})

      # Ended between two of its batches, holding no connection.
      Prima.Test.Wait.wait_until(
        fn -> Enum.map(inputs(ctx, turn), & &1.dispatch_state) == ["closed"] end,
        10_000,
        "the post's acceptance to commit"
      )

      _ = :sys.get_state(attendant)
      Process.exit(attendant, :kill)

      line = "#{@title} stopped before it finished."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == [line]
    end

    test "a session closed on purpose while its turn waits ends the wait and says nothing in " <>
           "the thread",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      Prima.Test.Wait.wait_until(
        fn -> Enum.map(inputs(ctx, turn), & &1.dispatch_state) == ["closed"] end,
        10_000,
        "the post's acceptance to commit"
      )

      :ok = Aqua.Program.close(ctx.athanor_id, thread.id, turn.agent)

      assert :cancelled = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == []
    end

    test "a session forgotten while its turn waits ends as a close does: it opens nothing " <>
           "again and says nothing in the thread",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      Prima.Test.Wait.wait_until(
        fn -> Enum.map(inputs(ctx, turn), & &1.dispatch_state) == ["closed"] end,
        10_000,
        "the post's acceptance to commit"
      )

      # A home's reset forgets the thread's session and closes its holder
      # once that commits (`Opus.Programs.home/3`).
      thread_id = thread.id

      assert {:ok, [%{thread_id: ^thread_id}] = forgotten} =
               Arca.ThreadStorage.forget_sessions(Sanctum.Context.actor(ctx), [turn.agent])

      :ok = Opus.Brain.forgotten(ctx.athanor_id, forgotten)

      Prima.Test.Wait.wait_until(
        fn -> not Aqua.Program.holding?(ctx.athanor_id, thread.id, turn.agent) end,
        10_000,
        "the attendant to let its session go"
      )

      :ok = Aqua.Program.close(ctx.athanor_id, thread.id, turn.agent)
      assert :cancelled = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == []
    end

    test "the silence does not run out while an ask's call runs, and runs once its answer is " <>
           "taken",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      silence!(2_000)
      turn = accept!(ctx, thread, row, "run it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      opening = held_start!(fake, row, turn, "ask-1")
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")

      # Three silences pass while the call runs, and the clock stands still.
      refute_receive {:session, "close", _wire, _fields}, 6_000
      assert %{dispatch_state: "dispatched"} = step_by_key(ctx, turn, key)
      assert {:ok, %{status: "running"}} = Tape.turn(ctx, turn.id)

      assert TurnStorage.brain_silence(Sanctum.Context.actor(ctx), thread.id) ==
               {:ok, %{expired?: false, due_ms: nil}}

      assert system_lines(ctx, thread, turn) == []

      # Its answer taken, the program owes output again, and its silence
      # ends the work.
      send(opening, :go)
      assert %{"t" => "answer", "ask" => "ask-1", "id" => answer} = sent()
      say(fake, row, %{"t" => "accepted", "id" => answer})
      line = "#{@title} said nothing for 0 minutes, so its work here ended."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert system_lines(ctx, thread, turn) == [line]
      assert %{dispatch_state: "closed", outcome: "ok"} = step_by_key(ctx, turn, key)
    end
  end

  describe "an external tool's ask" do
    test "one no turn offers is decided denied and answered as an error, one with a null " <>
           "argument is refused before it runs, and the turn completes",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "search for it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      refute "github__search" in Enum.map(spec!(ctx, turn).tools, & &1["name"])

      say(fake, row, ask(turn, "ask-1", "github__search", %{"q" => "x"}))
      refused = sent()
      denied = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1"))
      {:ok, denial} = Tape.message(ctx, denied.result_message_id)
      [_post, told] = inputs(ctx, turn)

      assert refused == %{
               "t" => "answer",
               "id" => told.id,
               "ask" => "ask-1",
               "content" => denial.content,
               "is_error" => true
             }

      assert {denied.tool, denied.action, denied.dispatch_state, denied.outcome, denied.error} ==
               {"github:search", nil, "closed", "denied",
                "github__search is not one of the tools this work has"}

      say(fake, row, accepted(told))

      say(fake, row, ask(turn, "ask-2", "github__search", %{"q" => nil}))
      answer = sent()
      null = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-2"))
      [_post, _told, answered] = inputs(ctx, turn)

      assert answer == %{
               "t" => "answer",
               "id" => answered.id,
               "ask" => "ask-2",
               "content" =>
                 "github__search: the argument q is null; leave it out or give it a value",
               "is_error" => true
             }

      assert {null.dispatch_state, null.outcome} == {"closed", "denied"}

      say(fake, row, accepted(answered))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end
  end

  # ---------------------------------------------------------------------------
  # The brain's row, the turn and its decision

  defp brain_row!(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude-code",
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

  # A turn of the soul on `row`'s brain: the person's post, and the
  # program row pinned before the loop builds it (`Aqua.Loop.Turn`).
  defp accept!(ctx, thread, row, text, payload \\ nil, id \\ nil) do
    message =
      %{author: ctx.user_id, sent_by: "person", content: text}
      |> then(&if(payload, do: Map.put(&1, :payload, payload), else: &1))
      |> then(&if(id, do: Map.put(&1, :id, id), else: &1))

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: message,
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, turn} =
      TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row.id, %{fence: turn.fence})

    turn
  end

  # An app of the person's own with no exit, granted with nothing to bind.
  defp quiet_app!(ctx) do
    name = "program-app-#{System.unique_integer([:positive])}"

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
      })

    ref = "reagent:local." <> name
    decisions = %{ref: ref, bindings: []}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
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

  # The soul switched to read-only, as the Aqua page switches it.
  defp read_only!(ctx) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => Compendium.AquaPath.soul_name(),
        "mode" => "read-only"
      })
  end

  # The program's silence, below the roster's floor so a test can wait it
  # out, stored as an operator's write is and dropped from the cache.
  defp silence!(ms) do
    {:ok, %{revision: revision}} = Arca.PlatformSettings.all()
    {:ok, _next} = Arca.PlatformSettings.put("program_silence_ms", ms, revision, "test")
    Arca.PlatformSettings.invalidate("program_silence_ms")
    on_exit(fn -> Arca.PlatformSettings.invalidate("program_silence_ms") end)
    assert Opus.Brain.silence_ms() == ms
  end

  # A post the person writes into the open turn `turn`, with `payload`
  # (its attachments) when one is given, under `id` when its files were
  # stored under it (`stored!/3`).
  defp steer!(ctx, thread, turn, text, payload \\ nil, id \\ nil) do
    message =
      %{author: ctx.user_id, sent_by: "person", content: text}
      |> then(&if(payload, do: Map.put(&1, :payload, payload), else: &1))
      |> then(&if(id, do: Map.put(&1, :id, id), else: &1))

    {:ok, %{message: steer}} =
      Tape.accept(ctx, thread.id, %{message: message, steer_turn_id: turn.id})

    steer
  end

  # The startup options the turn names, as a crew request sets them.
  defp options!(turn, options) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [options: Jason.encode!(%{"brain_options" => options})]
      )
  end

  # Files stored under a post not yet written: its id and their refs.
  defp stored!(ctx, thread, files) do
    id = Prima.UUID7.generate_id("msg")
    {:ok, refs} = Aqua.Attachments.store(ctx, thread.id, id, files)
    {id, refs}
  end

  # A file copied from a post of the thread `thread`.
  defp brief(thread),
    do: %{
      "id" => "att_#{thread}",
      "filename" => "brief.txt",
      "media_type" => "text/plain",
      "read_threads" => [thread]
    }

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  # The spec the loop built for the running turn, built again as a resumed
  # loop builds it: its system prompt and tools are what the driver is given.
  defp spec!(ctx, turn) do
    {:ok, turn} = Tape.turn(ctx, turn.id)

    {:ok, authority} =
      Opus.authority_for(ctx, {:id, turn.profile_id}, Prima.AgentRef.soul_ref(),
        budget_id: turn.budget_id
      )

    {:ok, spec} = Aqua.Loop.Turn.build(ctx, turn, authority: authority, excerpt?: false)
    spec
  end

  # The prompt's last line is the clock, by the minute.
  defp without_clock(system), do: String.replace(system, ~r/Current date: .*\z/s, "")

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  # ---------------------------------------------------------------------------
  # Rows

  defp start_step(ctx, turn), do: step_by_key(ctx, turn, TurnStorage.brain_start_key(turn.id))

  defp step_by_key(ctx, turn, key) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &(&1.idempotency_key == key))
  end

  # The step keyed `key`, once it closed.
  defp closed!(ctx, turn, key) do
    Prima.Test.Wait.wait_until(
      fn -> match?(%{dispatch_state: "closed"}, step_by_key(ctx, turn, key)) end,
      10_000,
      "the step #{key} to close"
    )

    step_by_key(ctx, turn, key)
  end

  defp inputs(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.filter(steps, &(&1.kind == "input"))
  end

  # The ids of the turn's result rows, in order.
  defp result_rows(ctx, turn) do
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^ctx.athanor_id and m.turn_id == ^turn.id,
      where: m.kind == "tool_result",
      order_by: [asc: m.seq],
      select: m.id
    )
    |> Arca.Repo.all()
  end

  defp step_fields(step) do
    step
    |> Map.take([
      :kind,
      :purpose,
      :tool,
      :action,
      :dispatch_state,
      :outcome,
      :idempotency_key,
      :message_id,
      :usage
    ])
    |> Map.update!(:usage, &(&1 && Jason.decode!(&1)))
  end

  # An input step delivering `row_id`, closed `outcome` or still
  # dispatched (nil), keyed by the generation and what it delivers.
  defp input_fields(action, row_id, outcome, key \\ nil) do
    %{
      kind: "input",
      purpose: "brain",
      tool: "program",
      action: action,
      dispatch_state: if(outcome, do: "closed", else: "dispatched"),
      outcome: outcome,
      idempotency_key: (key || "0:#{action}:") <> row_id,
      message_id: row_id,
      usage: nil
    }
  end

  defp call_row(ctx, step) do
    {:ok, call} = Tape.message(ctx, step.message_id)
    {call.kind, call.content, Tape.payload(call)}
  end

  defp carried_by(ctx, message_id) do
    {:ok, %{carried_by: carried_by}} = Tape.message(ctx, message_id)
    carried_by
  end

  defp said_rows(ctx, thread, turn) do
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^ctx.athanor_id and m.thread_id == ^thread.id,
      where: m.turn_id == ^turn.id and m.sent_by == "aqua" and m.kind == "text",
      order_by: [asc: m.seq]
    )
    |> Arca.Repo.all()
    |> Enum.map(&{&1.author, &1.sent_by, &1.kind, &1.content, Tape.payload(&1)})
  end

  defp system_lines(ctx, thread, turn) do
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^ctx.athanor_id and m.thread_id == ^thread.id,
      where: m.turn_id == ^turn.id and m.kind == "system",
      order_by: [asc: m.seq],
      select: m.content
    )
    |> Arca.Repo.all()
  end

  # ---------------------------------------------------------------------------
  # The driver

  defp say(fake, row, event) when is_map(event),
    do: Scripted.write(fake, row.id, Jason.encode!(event))

  defp hello(boot),
    do: %{
      "t" => "hello",
      "v" => Opus.Brain.Wire.version(),
      "driver" => "cyfr-claude-code",
      "boot" => boot
    }

  # The next command the holder wrote to the driver.
  defp sent(timeout \\ 10_000) do
    assert_receive {:session, "send", %{"lines" => [line]}, _fields}, timeout
    Jason.decode!(line)
  end

  # The driver's session opens and says hello once it stands: the open is
  # told before its session does.
  defp opened!(fake, row, boot) do
    assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 10_000
    assert home == row.id

    Prima.Test.Wait.wait_until(
      fn -> running_sessions(fake, row) != [] end,
      10_000,
      "the driver's session to stand"
    )

    say(fake, row, hello(boot))
  end

  # The driver's session opens, starts and takes the turn's work: the
  # start and the work it was given.
  defp started!(fake, row, boot \\ "boot-one") do
    opened!(fake, row, boot)
    begun!(fake, row)
  end

  # The opened driver starts the harness, which takes the turn's work.
  defp begun!(fake, row) do
    start = sent()
    assert %{"t" => "start"} = start
    say(fake, row, started([]))
    work = sent()
    assert %{"t" => "work", "id" => id} = work
    say(fake, row, %{"t" => "accepted", "id" => id})
    %{start: start, work: work}
  end

  defp started(held),
    do: %{"t" => "started", "session" => @session, "fresh" => held == [], "held" => held}

  defp running_sessions(fake, row),
    do: fake |> Scripted.sessions(row.id) |> Enum.filter(fn {_id, s} -> s.running end)

  defp posted(input, turn, text, files \\ []),
    do: %{
      "t" => "post",
      "id" => input.id,
      "work" => turn.id,
      "content" => [%{"type" => "text", "text" => text} | files]
    }

  defp accepted(input), do: %{"t" => "accepted", "id" => input.id}

  # The next command written, taken by the driver.
  defp accept_next!(fake, row) do
    command = sent()
    say(fake, row, %{"t" => "accepted", "id" => command["id"]})
    command
  end

  # The recovery prompt that continues a post the transcript holds.
  defp post_notice,
    do:
      "CYFR restarted while you were working on the last message, which you already have. " <>
        "Go on with it, or say where it stands."

  # The recovery prompt that carries an answer the session no longer asks for.
  defp answer_notice(name, ask, content),
    do:
      "CYFR restarted while your call #{name} (#{ask}) ran, so its answer comes as this " <>
        "message instead. It answered: " <> content

  defp said(turn, message, text),
    do: %{"t" => "said", "gen" => 0, "work" => turn.id, "message" => message, "text" => text}

  # A text event of `turn`'s work, of `work` when one is named, or of
  # none (`:none`).
  defp text(turn, message, delta, work \\ nil) do
    %{"t" => "text", "gen" => 0, "message" => message, "delta" => delta}
    |> then(&if(work == :none, do: &1, else: Map.put(&1, "work", work || turn.id)))
  end

  # The thread's events reach the test as they reach a viewer.
  defp watch!(ctx, thread) do
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, thread.id))
  end

  defp delta! do
    assert_receive %Cyfr.Bus.ThreadEvent{kind: :delta, data: delta}, 10_000
    delta
  end

  # A delta of the program's native message `message` in `turn`, as a
  # viewer keeps it (`Aqua.Loop.Stream`): the soul's role is nil.
  defp streamed(turn, fence, message, ordinal, seq, text),
    do: Map.merge(marker(turn, fence, message, ordinal), %{role: nil, seq: seq, text: text})

  defp marker(turn, fence, message, ordinal),
    do: %{turn_id: turn.id, fence: fence, source: turn.id, step_id: message, ordinal: ordinal}

  defp ask(turn, ask, name, arguments, work \\ nil),
    do: %{
      "t" => "ask",
      "gen" => 0,
      "work" => work || turn.id,
      "ask" => ask,
      "name" => name,
      "arguments" => arguments
    }

  # The program asks, as `ask`, to run its own row on a terminal, a call
  # that does more than read, answering as soon as it opens; the open is
  # held until the test sends `:go` to what this answers, so the call runs
  # on meanwhile.
  defp held_start!(fake, row, turn, ask) do
    Scripted.hold(fake, "open", 120_000)
    say(fake, row, ask(turn, ask, "program", start_args(row)))
    assert_receive {:held, "open", opening}, 10_000
    opening
  end

  defp start_args(row),
    do: %{"action" => "start", "program" => row.id, "epoch" => row.epoch, "wait_ms" => 0}

  defp counts,
    do: %{
      "input_tokens" => 10,
      "output_tokens" => 4,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0
    }

  defp usage(turn, result),
    do: %{
      "t" => "usage",
      "gen" => 0,
      "work" => turn.id,
      "result" => result,
      "accounting" => "complete",
      "models" => [%{"model" => "m", "counts" => counts()}]
    }

  defp idle(turn, answered),
    do: %{
      "t" => "idle",
      "gen" => 0,
      "work" => turn.id,
      "answered" => answered,
      "stop" => "end_turn"
    }

  # The attendant committed the session's lines through `seq`.
  defp committed!(ctx, thread, seq) do
    Prima.Test.Wait.wait_until(
      fn ->
        match?(
          {:ok, %{progress: %{"seq" => at}}} when at >= seq,
          TurnStorage.brain(Sanctum.Context.actor(ctx), thread.id)
        )
      end,
      10_000,
      "the attendant committed line #{seq}"
    )
  end
end
