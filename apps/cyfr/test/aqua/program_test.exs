# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ProgramTest do
  @moduledoc """
  A program used as a brain through the real loop and the real attendant
  (`Aqua.Program`), the test playing the brain's driver against the
  scripted backends service as `Opus.BrainTest` does.

  A turn on a program brain opens with the host's `program.start` of the
  brain's row, decided as a model's is and attended: the driver is given
  its start, the turn's work and the turn's post. What the program says is
  a post of its agent, its usage is counted once, and the turn completes on
  the `idle` that answers every post it was given, one written while it
  works included. Its asks are steps the loop decides and runs, answered
  with their results; an ask of a tool the turn does not offer is refused,
  and one of other work writes no step and closes the session. A start
  nobody allowed waits on its
  card, and a schedule's opens none. A holder's end resumes the native
  session with the posts whose delivery its transcript says: one it holds
  is continued by one notice, one it does not ends the turn. A transcript
  the harness no longer has starts over, the thread its context, and in
  the middle of the work one prompt carries what its calls answered. Stop
  closes the session first. A program turn has no deadline, and the
  program's own silence ends it, never while a card waits.
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
    test "opens with the host's start, allowed standing, and completes on the idle that answers its post",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
      turn = accept!(ctx, thread, row, "what is in notes.md?")
      loop = run(ctx, turn)

      %{start: start, work: work} = started!(fake, row)
      spec = spec!(ctx, turn)
      start_step = start_step(ctx, turn)

      assert Map.delete(start, "system") == %{
               "t" => "start",
               "gen" => 0,
               "config" => %{"model" => spec.agent["model"]}
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

      # The start was the host's, decided by the standing allow: no card.
      assert {:ok, %{status: "completed"} = ended} = Tape.turn(ctx, turn.id)
      assert {:ok, []} = Tape.pending_approvals(ctx, ended)

      assert step_fields(start_step(ctx, turn)) == %{
               kind: "tool",
               purpose: "brain",
               tool: "program",
               action: "start",
               dispatch_state: "closed",
               outcome: "ok",
               approval_id: nil,
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

      # What the program said is a post of its agent in the thread.
      assert said_rows(ctx, thread, turn) == [
               {Arca.Schemas.Message.agent_author(), "aqua", "text",
                "notes.md holds three lines.", %{"brain_message" => "msg_1"}}
             ]
    end

    test "takes a post written while the program works at once, and completes only on the idle that answers it too",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

  describe "the program's asks" do
    test "an ask of the open turn is a step the loop decides and runs, answered with its result; one of a tool not offered is refused",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)

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
  end

  describe "its start's decision" do
    test "without a standing allow the start waits on its card, and the driver is given nothing until it is approved",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "hello")
      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)

      refute_received {:session, "open", _wire, _fields}
      refute_received {:session, "send", _wire, _fields}
      %{approval: approval, intent: intent} = pending_card(ctx, turn)

      # The card shows the start of the brain's row, its pinned command.
      assert intent == %{
               "action_kind" => "execute",
               "id" => approval.id,
               "kind" => "request_approval",
               "program" => %{
                 "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
                 "epoch" => row.epoch,
                 "folder" => "its own folder",
                 "hosts" => "every public host",
                 "name" => "claude-code",
                 "row" => row.id
               },
               "proposal" => %{
                 "action" => "start",
                 "args" => %{"epoch" => row.epoch, "program" => row.id},
                 "tool" => "program"
               },
               "purpose" => "brain",
               "sources" => [],
               "standing" => nil,
               "summary" => "",
               "title" => "program.start",
               "tool_call_id" => "start"
             }

      assert {:ok, %{decision: "approved"}} =
               Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: :once})

      loop = resume(ctx, turn)
      %{work: work} = started!(fake, row)
      start_step = start_step(ctx, turn)
      assert work["id"] == start_step.id
      assert start_step.approval_id == approval.id
      post = sent()
      [input] = inputs(ctx, turn)
      assert post == posted(input, turn, "hello")
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "a standing never recorded while the program works ends the turn at its next write, which is never written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
      turn = accept!(ctx, thread, row, "work on it")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      allow!(ctx, thread, row, :never)

      {:ok, %{message: steer}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "and this"},
          steer_turn_id: turn.id
        })

      line = "#{@title} may not go on with this work any more."
      assert {:failed, ^line} = Task.await(loop, 15_000)
      assert system_lines(ctx, thread, turn) == [line]
      assert carried_by(ctx, steer.id) == nil

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok")
             ]

      assert running_sessions(fake, row) == []
      refute_received {:session, "send", _wire, _fields}
    end

    test "what the program is given first joins the turn before its start is decided: its " <>
           "instructions' sources, its post's and the thread's a fresh session reads are on " <>
           "the card, and once allowed its post is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      # Its instructions carry a note kept from outside, the thread an
      # earlier post that brought outside material, and its own post too.
      {:ok, _} =
        Aqua.Notes.keep(ctx, "clip", "Fares rise on Monday",
          sources: [Prima.Source.outside("news.example")]
        )

      {:ok, _earlier} =
        Tape.append(ctx, thread.id, %{
          author: ctx.user_id,
          sent_by: "person",
          kind: "text",
          content: "from the wire",
          payload: %{"attachments" => [brief("wire.example")]}
        })

      allow!(ctx, thread, row)

      turn =
        accept!(ctx, thread, row, "read this brief", %{"attachments" => [brief("post.example")]})

      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)
      refute_received {:session, "open", _wire, _fields}
      %{approval: card, intent: intent} = pending_card(ctx, turn)

      assert intent["sources"] == [
               %{"class" => "filed", "name" => nil},
               %{"class" => "outside", "name" => "news.example"},
               %{"class" => "outside", "name" => "post.example"},
               %{"class" => "outside", "name" => "wire.example"}
             ]

      approve!(ctx, card)
      loop = resume(ctx, turn)
      %{start: start} = started!(fake, row)
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
      allow!(ctx, thread, row)
      turn = accept!(ctx, thread, row, "plan only")
      options!(turn, %{"permission_mode" => "plan", "effort" => "high"})
      loop = run(ctx, turn)
      %{start: start} = started!(fake, row)

      assert start["config"] == %{
               "model" => spec!(ctx, turn).agent["model"],
               "permission_mode" => "plan",
               "effort" => "high"
             }

      post = sent()
      [input] = inputs(ctx, turn)
      assert post == posted(input, turn, "plan only")
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
    end

    test "a startup option the harness does not take is refused before anything is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

    test "a scheduled turn with no standing allow opens no card and ends failed saying what it needed",
         %{ctx: ctx, thread: thread, row: row} do
      ctx = %{ctx | origin: :schedule}
      turn = accept!(ctx, thread, row, "hello")
      _ = Task.await(run(ctx, turn), 30_000)

      needed =
        "This scheduled run needed your approval to use program.start, and nobody was here " <>
          "to give it. To allow it next time, ask Aqua for it once on your daily thread and " <>
          "choose \"for a schedule\", naming this one, when it asks."

      assert {:ok, %{status: "failed", error: ^needed} = ended} = Tape.turn(ctx, turn.id)
      assert {:ok, []} = Tape.pending_approvals(ctx, ended)

      assert Map.take(start_step(ctx, turn), [:dispatch_state, :outcome, :error, :approval_id]) ==
               %{dispatch_state: "closed", outcome: "denied", error: needed, approval_id: nil}

      assert inputs(ctx, turn) == []
      refute_received {:session, "open", _wire, _fields}
    end
  end

  describe "recovery" do
    test "a holder's end resumes the native session naming the post, and a post its transcript holds is continued by one notice",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

    test "a post the resumed transcript does not hold ends the turn saying so, and is never written again",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

    test "a transcript the harness no longer has starts over, and the next post carries the thread as its context",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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
      stopping = Task.async(fn -> Aqua.Loop.abort(ctx, open, "stopped") end)

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

    test "a program turn has no deadline: one whose active time is past its turn's keeps running",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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

    test "an attendant that ends while its turn waits on it ends the turn, saying so",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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

    test "the silence does not run out while an ask's card waits",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      silence!(2_000)
      allow!(ctx, thread, row)
      turn = accept!(ctx, thread, row, "write it down")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      say(
        fake,
        row,
        ask(turn, "ask-1", "files", %{"action" => "write", "path" => "a.md", "content" => "x"})
      )

      assert {:paused, :approval} = Task.await(loop, 30_000)
      assert %{approval: %{status: "pending"}} = pending_card(ctx, turn)

      refute_receive {:session, "close", _wire, _fields}, 6_000
      assert {:ok, %{status: "paused"}} = Tape.turn(ctx, turn.id)
      assert system_lines(ctx, thread, turn) == []
      assert [_running] = running_sessions(fake, row)
    end
  end

  describe "an external tool's ask" do
    test "one no turn offers is decided denied and answered as an error, one with a null " <>
           "argument is refused before it runs, and the turn completes",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

      assert {null.dispatch_state, null.outcome, null.proposal_digest} ==
               {"closed", "denied", nil}

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
  defp accept!(ctx, thread, row, text, payload \\ nil) do
    message =
      %{author: ctx.user_id, sent_by: "person", content: text}
      |> then(&if(payload, do: Map.put(&1, :payload, payload), else: &1))

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: message,
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, turn} =
      TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row.id, %{fence: turn.fence})

    turn
  end

  # A standing answer to the soul's `program.start` of `row` in this
  # thread (or a never), recorded through Sanctum as a card's answer
  # records one.
  defp allow!(ctx, thread, row, scope \\ :thread) do
    {:ok, [grant]} =
      Aqua.Standing.rows(
        ctx,
        %{id: "turn_none", thread_id: thread.id, agent: "aqua", root_execution_id: nil},
        %{
          "tool" => "program",
          "action" => "start",
          "args" => %{"program" => row.id, "epoch" => row.epoch}
        },
        scope
      )

    {:ok, _} = Sanctum.ToolGrants.put(ctx, grant)
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

  # A post the person writes into the open turn `turn`.
  defp steer!(ctx, thread, turn, text) do
    {:ok, %{message: steer}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        steer_turn_id: turn.id
      })

    steer
  end

  # The person's yes on a card, for this call alone.
  defp approve!(ctx, approval) do
    assert {:ok, %{decision: "approved"}} =
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: :once})
  end

  # The startup options the turn names, as a crew request sets them.
  defp options!(turn, options) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [options: Jason.encode!(%{"brain_options" => options})]
      )
  end

  # A file copied from material that came from `host`.
  defp brief(host),
    do: %{
      "id" => "att_#{host}",
      "filename" => "brief.txt",
      "media_type" => "text/plain",
      "sources" => [%{"class" => "outside", "name" => host}]
    }

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  defp resume(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)

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

  defp pending_card(ctx, turn) do
    {:ok, fresh} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, fresh)
    {:ok, card} = Tape.message(ctx, approval.message_id)
    %{approval: approval, intent: Tape.payload(card)["intent"]}
  end

  # ---------------------------------------------------------------------------
  # Rows

  defp start_step(ctx, turn), do: step_by_key(ctx, turn, TurnStorage.brain_start_key(turn.id))

  defp step_by_key(ctx, turn, key) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &(&1.idempotency_key == key))
  end

  defp inputs(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.filter(steps, &(&1.kind == "input"))
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
      :approval_id,
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
      approval_id: nil,
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
    do: %{"t" => "hello", "v" => 1, "driver" => "cyfr-claude-code", "boot" => boot}

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

  defp posted(input, turn, text),
    do: %{
      "t" => "post",
      "id" => input.id,
      "work" => turn.id,
      "content" => [%{"type" => "text", "text" => text}]
    }

  defp accepted(input), do: %{"t" => "accepted", "id" => input.id}

  defp said(turn, message, text),
    do: %{"t" => "said", "gen" => 0, "work" => turn.id, "message" => message, "text" => text}

  defp ask(turn, ask, name, arguments, work \\ nil),
    do: %{
      "t" => "ask",
      "gen" => 0,
      "work" => work || turn.id,
      "ask" => ask,
      "name" => name,
      "arguments" => arguments
    }

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
