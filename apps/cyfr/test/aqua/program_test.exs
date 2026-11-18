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
  and one of other work writes no step and closes the session. A post and
  an answer owed together are written one at a time, the answer first. A
  post written while an ask's card waits is written at once and approves
  nothing, and an ask made then is recorded and decided when the turn
  goes on, under what holds then. A start nobody allowed waits on its
  card, and a schedule's opens none; a session left from the turn before
  is written nothing while the next waits on its own; a post that brings
  in what the start's card did not show ends the turn; and new startup
  options restart the driver, resuming. A holder's end resumes the native
  session with the posts whose delivery its transcript says: one it holds
  is continued by one notice, one it does not ends the turn, and an
  answer the resumed session no longer asks for comes as one notice that
  names its call, attempted once. A transcript the harness no longer has
  starts over, the thread its context, and in the middle of the work one
  prompt carries what its calls answered. Stop closes the session first,
  during a CYFR tool too. A program turn has no deadline, and the
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

    test "a post and a tool's answer owed together are written one at a time, the answer " <>
           "first, each once",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

    test "a post written while an ask's card waits is written at once and approves nothing; " <>
           "approved, the ask runs and its answer follows",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
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
        ask(turn, "ask-1", "files", %{
          "action" => "write",
          "path" => "data/a.md",
          "content" => "x"
        })
      )

      assert {:paused, :approval} = Task.await(loop, 30_000)
      %{approval: card} = pending_card(ctx, turn)
      key = TurnStorage.brain_ask_key(turn.id, "ask-1")

      steer = steer!(ctx, thread, turn, "and this")
      post = sent()
      [_input, steered] = inputs(ctx, turn)
      assert post == posted(steered, turn, "and this")
      say(fake, row, accepted(steered))
      closed!(ctx, turn, steered.idempotency_key)

      # The card still waits, and the turn with it.
      assert %{approval: %{id: card_id, status: "pending"}} = pending_card(ctx, turn)
      assert card_id == card.id
      assert {:ok, %{status: "paused"}} = Tape.turn(ctx, turn.id)

      assert Map.take(step_by_key(ctx, turn, key), [:dispatch_state, :outcome, :approval_id]) ==
               %{dispatch_state: "proposed", outcome: nil, approval_id: card.id}

      approve!(ctx, card)
      loop = resume(ctx, turn)
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

      assert Map.take(written, [:tool, :action, :dispatch_state, :outcome, :approval_id]) ==
               %{
                 tool: "files",
                 action: "write",
                 dispatch_state: "closed",
                 outcome: "ok",
                 approval_id: card.id
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

    test "asks made while a card waits are recorded and dispatched by none, and are decided " <>
           "when the turn goes on, under the authority and the sources that hold then",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      outside = Prima.Source.outside("news.example")
      allow!(ctx, thread, row, :thread, %{sources: [outside]})
      standing!(ctx, thread, "files", "write", %{"path" => "data/b.md"}, :thread)
      turn = accept!(ctx, thread, row, "tidy up")
      loop = run(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))

      say(
        fake,
        row,
        ask(turn, "ask-1", "notes", %{"action" => "keep", "name" => "todo", "content" => "tidy"})
      )

      assert {:paused, :approval} = Task.await(loop, 30_000)
      %{approval: card} = pending_card(ctx, turn)

      # While the card waits the program asks for a write the standing
      # allow covers now, and for a list: each recorded, neither run.
      say(
        fake,
        row,
        ask(turn, "ask-2", "files", %{
          "action" => "write",
          "path" => "data/b.md",
          "content" => "y"
        })
      )

      say(fake, row, ask(turn, "ask-3", "program", %{"action" => "list"}))
      committed!(ctx, thread, 7)
      write_key = TurnStorage.brain_ask_key(turn.id, "ask-2")
      list_key = TurnStorage.brain_ask_key(turn.id, "ask-3")

      for key <- [write_key, list_key] do
        assert Map.take(step_by_key(ctx, turn, key), [:dispatch_state, :outcome, :approval_id]) ==
                 %{dispatch_state: "proposed", outcome: nil, approval_id: nil}
      end

      refute_receive {:session, "send", _wire, _fields}, 500

      # Then a never on the list is recorded, and a post brings in outside
      # material, which joins the turn as it is written.
      standing!(ctx, thread, "program", "list", %{}, :never)

      steer =
        steer!(ctx, thread, turn, "and this brief", %{"attachments" => [brief("news.example")]})

      post = sent()
      [_input, steered] = inputs(ctx, turn)
      assert post == posted(steered, turn, "and this brief")
      say(fake, row, accepted(steered))
      {:ok, paused} = Tape.turn(ctx, turn.id)
      assert Prima.Source.decode(paused.sources) == [program_source(row), outside]

      for key <- [write_key, list_key] do
        assert %{dispatch_state: "proposed"} = step_by_key(ctx, turn, key)
      end

      # Approved, the card's ask runs; the list is refused by the never;
      # the write asks on a card of its own, which shows the outside
      # source the allow does not cover.
      approve!(ctx, card)
      assert {:paused, :approval} = Task.await(resume(ctx, turn), 30_000)

      kept = step_by_key(ctx, turn, TurnStorage.brain_ask_key(turn.id, "ask-1"))
      listed = step_by_key(ctx, turn, list_key)
      writing = step_by_key(ctx, turn, write_key)

      assert Map.take(kept, [:tool, :action, :dispatch_state, :outcome, :approval_id]) ==
               %{
                 tool: "notes",
                 action: "keep",
                 dispatch_state: "closed",
                 outcome: "ok",
                 approval_id: card.id
               }

      assert Map.take(listed, [:tool, :action, :dispatch_state, :outcome, :approval_id]) ==
               %{
                 tool: "program",
                 action: "list",
                 dispatch_state: "closed",
                 outcome: "denied",
                 approval_id: nil
               }

      %{approval: second_card, intent: intent} = pending_card(ctx, turn)
      assert second_card.step_id == writing.id

      assert intent["proposal"] == %{
               "tool" => "files",
               "action" => "write",
               "args" => %{"path" => "data/b.md", "content" => "y"}
             }

      assert intent["sources"] == [
               %{"class" => "outside", "name" => "claude-code"},
               %{"class" => "outside", "name" => "news.example"}
             ]

      assert Map.take(writing, [:dispatch_state, :outcome, :approval_id]) ==
               %{dispatch_state: "proposed", outcome: nil, approval_id: second_card.id}

      # The two closed asks are answered while the new card waits, each once.
      answers =
        for _ <- 1..2 do
          answer = sent()
          say(fake, row, %{"t" => "accepted", "id" => answer["id"]})
          answer
        end

      {:ok, kept_result} = Tape.message(ctx, kept.result_message_id)
      {:ok, denial} = Tape.message(ctx, listed.result_message_id)

      assert answers |> Enum.map(&Map.delete(&1, "id")) |> Enum.sort_by(& &1["ask"]) == [
               %{
                 "t" => "answer",
                 "ask" => "ask-1",
                 "content" => kept_result.content,
                 "is_error" => false
               },
               %{
                 "t" => "answer",
                 "ask" => "ask-3",
                 "content" => denial.content,
                 "is_error" => true
               }
             ]

      approve!(ctx, second_card)
      loop = resume(ctx, turn)
      answer = sent()
      written = step_by_key(ctx, turn, write_key)
      {:ok, write_result} = Tape.message(ctx, written.result_message_id)

      assert Map.delete(answer, "id") == %{
               "t" => "answer",
               "ask" => "ask-2",
               "content" => write_result.content,
               "is_error" => false
             }

      assert %{dispatch_state: "closed", outcome: "ok"} = written
      say(fake, row, %{"t" => "accepted", "id" => answer["id"]})
      say(fake, row, idle(turn, [input.id, steered.id]))
      assert :completed = Task.await(loop, 30_000)
      assert carried_by(ctx, steer.id) == steered.id
      refute_received {:session, "send", _wire, _fields}
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
               "sources" => [%{"class" => "outside", "name" => "claude-code"}],
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

    test "the program itself is an outside source its turn reads from the start: a standing " <>
           "allow that does not follow it asks on the card, and the turn keeps it",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      args = %{"program" => row.id, "epoch" => row.epoch}
      standing!(ctx, thread, "program", "start", args, :thread)
      turn = accept!(ctx, thread, row, "look it up")
      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)
      refute_received {:session, "open", _wire, _fields}
      %{approval: card, intent: intent} = pending_card(ctx, turn)
      assert intent["sources"] == [%{"class" => "outside", "name" => row.name}]

      approve!(ctx, card)
      loop = resume(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)
      {:ok, working} = Tape.turn(ctx, turn.id)
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      assert Prima.Source.decode(working.sources) == [program_source(row)]
    end

    test "a post written while the start's card waits skips nothing and is written nothing " <>
           "until the start is allowed, then follows the post that opened the turn",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "hello")
      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)
      %{approval: card} = pending_card(ctx, turn)
      steer = steer!(ctx, thread, turn, "and this")

      refute_receive {:session, "open", _wire, _fields}, 1_000
      assert inputs(ctx, turn) == []
      assert carried_by(ctx, steer.id) == nil
      assert %{approval: %{id: card_id, status: "pending"}} = pending_card(ctx, turn)
      assert card_id == card.id

      approve!(ctx, card)
      loop = resume(ctx, turn)
      %{work: work} = started!(fake, row)
      assert work["id"] == start_step(ctx, turn).id
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

      assert Map.take(start_step(ctx, turn), [:dispatch_state, :outcome, :approval_id]) ==
               %{dispatch_state: "closed", outcome: "ok", approval_id: card.id}

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok"),
               input_fields("post", steer.id, "ok")
             ]

      assert system_lines(ctx, thread, turn) == []
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

    test "a post that brings in material its start's card did not show ends the turn at its " <>
           "write, which is never written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "work on it")
      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)

      %{
        approval: card,
        intent: %{"sources" => [%{"class" => "outside", "name" => "claude-code"}]}
      } =
        pending_card(ctx, turn)

      approve!(ctx, card)
      loop = resume(ctx, turn)
      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      steer =
        steer!(ctx, thread, turn, "and this brief", %{"attachments" => [brief("news.example")]})

      line =
        "This message brings in material the approval of #{@title} did not cover, so this " <>
          "work ends here. Send it again to be asked anew."

      assert {:failed, ^line} = Task.await(loop, 15_000)
      assert system_lines(ctx, thread, turn) == [line]
      assert carried_by(ctx, steer.id) == nil

      assert Enum.map(inputs(ctx, turn), &step_fields/1) == [
               input_fields("post", turn.message_id, "ok")
             ]

      # What the post brings in joined the turn before its write was
      # refused, and stays joined: the turn read it.
      {:ok, ended} = Tape.turn(ctx, turn.id)

      assert Prima.Source.decode(ended.sources) == [
               Prima.Source.outside("claude-code"),
               Prima.Source.outside("news.example")
             ]

      assert_receive {:session, "close", _wire, _fields}, 10_000
      assert running_sessions(fake, row) == []
      refute_received {:session, "send", _wire, _fields}
    end

    test "a session left from the turn before is written nothing while the next turn waits on " <>
           "its own start's card, and once allowed takes the next turn's work, then its posts",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      turn = accept!(ctx, thread, row, "first")
      assert {:paused, :approval} = Task.await(run(ctx, turn), 30_000)
      approve!(ctx, pending_card(ctx, turn).approval)
      loop = resume(ctx, turn)
      %{work: first_work} = started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      say(fake, row, idle(turn, [input.id]))
      assert :completed = Task.await(loop, 30_000)
      assert Aqua.Program.holding?(ctx.athanor_id, thread.id, "aqua")

      # The start of the turn before was allowed once, for that turn: the
      # next waits on a card of its own, and nothing of it is written.
      next = accept!(ctx, thread, row, "second")
      paused = run(ctx, next)
      refute_receive {:session, "send", _wire, _fields}, 2_000
      assert {:paused, :approval} = Task.await(paused, 30_000)
      %{approval: card} = pending_card(ctx, next)
      steer = steer!(ctx, thread, next, "and this")
      refute_receive {:session, "send", _wire, _fields}, 1_000
      refute_received {:session, "close", _wire, _fields}
      assert [_held] = running_sessions(fake, row)
      assert inputs(ctx, next) == []
      assert carried_by(ctx, next.message_id) == nil
      assert carried_by(ctx, steer.id) == nil

      # Allowed, the same session takes the turn's work, then its posts.
      approve!(ctx, card)
      loop = resume(ctx, next)
      work = sent()

      assert work == %{
               first_work
               | "id" => start_step(ctx, next).id,
                 "work" => next.id,
                 "tools" => json(spec!(ctx, next).tools)
             }

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

      refute_received {:session, "open", _wire, _fields}
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
               %{"class" => "outside", "name" => "claude-code"},
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

    test "a turn whose startup options differ from the running harness's closes its driver " <>
           "and starts a new one, resuming with them, before anything is written",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
                 "config" => %{"model" => spec!(ctx, next).agent["model"], "effort" => "high"}
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

    test "a notice the holder refuses before writing it leaves its post owed: the next start " <>
           "names the post again, and the notice follows once",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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

    test "the driver's death with a tool's answer held back by a post resumes each held post " <>
           "with one notice, and the answer as one notice that names its call",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
      allow!(ctx, thread, row)
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
      allow!(ctx, thread, row)
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

      committed!(ctx, thread, 5)

      # The answer was written and never taken when the driver ends.
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
      allow!(ctx, thread, row)
      turn = accept!(ctx, thread, row, "run it")
      tasks = start_supervised!(Task.Supervisor)

      loop =
        Task.Supervisor.async_nolink(tasks, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

      started!(fake, row)
      _post = sent()
      [input] = inputs(ctx, turn)
      say(fake, row, accepted(input))
      committed!(ctx, thread, 4)

      # The program asks to run its own row on a terminal, which the
      # thread's standing allow covers; the terminal's open is held.
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
               :approval_id,
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
               approval_id: nil,
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

    test "an idle of other work leaves the open work owing output: after a tool's answer is " <>
           "taken with no post owed, the program is still busy and its clock runs",
         %{ctx: ctx, thread: thread, row: row, fake: fake} do
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
        ask(turn, "ask-1", "files", %{
          "action" => "write",
          "path" => "data/b.md",
          "content" => "x"
        })
      )

      assert {:paused, :approval} = Task.await(loop, 30_000)
      %{approval: card} = pending_card(ctx, turn)
      say(fake, row, idle(turn, [input.id]))
      committed!(ctx, thread, 6)
      approve!(ctx, card)
      loop = resume(ctx, turn)
      assert %{"t" => "answer", "id" => answer} = sent()
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

    test "a session forgotten while its turn waits ends as a close does: it opens nothing " <>
           "again and says nothing in the thread",
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
  # records one. An allow follows the program itself, an outside source
  # the start reads (`Aqua.Loop`), and any other the bounds name.
  defp allow!(ctx, thread, row, scope \\ :thread, bounds \\ %{}) do
    bounds =
      if scope == :never,
        do: bounds,
        else: Map.update(bounds, :sources, [program_source(row)], &[program_source(row) | &1])

    standing!(
      ctx,
      thread,
      "program",
      "start",
      %{"program" => row.id, "epoch" => row.epoch},
      scope,
      bounds
    )
  end

  defp program_source(row), do: Prima.Source.outside(row.name)

  # A standing answer to the soul's `tool.action` in this thread, with
  # the bounds the person chose.
  defp standing!(ctx, thread, tool, action, args, scope, bounds \\ %{}) do
    {:ok, [grant]} =
      Aqua.Standing.rows(
        ctx,
        %{id: "turn_none", thread_id: thread.id, agent: "aqua", root_execution_id: nil},
        %{"tool" => tool, "action" => action, "args" => args},
        scope,
        bounds
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

  # A post the person writes into the open turn `turn`, with `payload`
  # (its attachments) when one is given.
  defp steer!(ctx, thread, turn, text, payload \\ nil) do
    message =
      %{author: ctx.user_id, sent_by: "person", content: text}
      |> then(&if(payload, do: Map.put(&1, :payload, payload), else: &1))

    {:ok, %{message: steer}} =
      Tape.accept(ctx, thread.id, %{message: message, steer_turn_id: turn.id})

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
