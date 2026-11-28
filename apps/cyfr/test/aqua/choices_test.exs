# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ChoicesTest do
  @moduledoc """
  Aqua's question with its choices as buttons: the block's one grammar,
  the one row of a turn that gives buttons, and a press through
  `thread.send` as the person, read again on the server and written as
  data. A card never closes. The rows the real brains write are
  `Aqua.CrewTest`'s (a model) and `Aqua.ProgramTest`'s (a program).
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Choices
  alias Aqua.Providers.Thread, as: Tool
  alias Arca.ThreadStorage, as: Threads

  setup do
    Cyfr.Test.Sandbox.setup!()
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id, origin: :interactive}
    Sanctum.TestContext.ready!(ctx.athanor_id)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, today} = Aqua.Day.current(ctx)
    {:ok, ctx: ctx, today: today}
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp block(tag, question \\ "Which database should the export target?", lines \\ nil),
    do:
      "```choices #{tag}\n#{question}\n" <>
        Enum.join(lines || ["- PostgreSQL", "- SQLite"], "\n") <> "\n```"

  # A soul turn of `thread`, opened by the person's line and left at
  # `status`, as its loop leaves it.
  defp turn!(ctx, thread, status \\ "completed") do
    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "export the notes"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    ended!(turn, status)
  end

  defp ended!(turn, status) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [status: status]
      )

    %{turn | status: status}
  end

  # A row of the turn as its brain says it (`Arca.TurnStorage`'s
  # `said!`): naming the model step, or with `marker` the native message.
  defp said!(ctx, thread, turn, content, payload \\ %{"step_id" => "stp_said"}) do
    {:ok, row} =
      Threads.append(actor(ctx), thread.id, %{
        author: Prima.Author.agent(),
        sent_by: turn.agent,
        kind: "text",
        content: content,
        payload: payload,
        turn_id: turn.id
      })

    row
  end

  # A press as a client sends one: its choice, and a client id.
  defp press(ctx, row, index, client_id \\ nil) do
    Tool.handle(
      "thread",
      ctx,
      %{"action" => "send", "choice" => %{"row" => row.id, "index" => index}}
      |> then(&if(client_id, do: Map.put(&1, "client_id", client_id), else: &1))
    )
  end

  describe "the block's grammar" do
    test "a reply that ends with a block reads its question, choices and file; anything else is text" do
      tag = "trn_0193a6a0-7f00-7000-8000-00000000000a"

      assert {:ok,
              %{
                tag: ^tag,
                question: "Which database should the export target?",
                choices: ["PostgreSQL", "SQLite"],
                file: nil,
                prose: "I can export either way."
              }} = Choices.parse("I can export either way.\n\n" <> block(tag) <> "\n\n")

      assert {:ok, %{choices: ["Proceed"], file: "data/aqua/plans/x-1-export.md", prose: ""}} =
               Choices.parse(
                 block(tag, "Go ahead?", ["- Proceed", "file: data/aqua/plans/x-1-export.md"])
               )

      assert {:ok, %{choices: ["Proceed"], file: nil}} =
               Choices.parse(block(tag, "Go ahead?", ["- Proceed"]))

      labels = fn n -> for i <- 1..n, do: "- choice #{i}" end
      ok = &match?({:ok, _}, Choices.parse(&1))

      # At each bound, and one past it.
      assert ok.(block(tag, String.duplicate("q", 200)))
      refute ok.(block(tag, String.duplicate("q", 201)))
      assert ok.(block(tag, "q", ["- " <> String.duplicate("l", 100)]))
      refute ok.(block(tag, "q", ["- " <> String.duplicate("l", 101)]))
      assert ok.(block(tag, "q", labels.(8)))
      refute ok.(block(tag, "q", labels.(9)))
      assert ok.(block(tag, "q", ["- a", "file: " <> String.duplicate("p", 512)]))
      refute ok.(block(tag, "q", ["- a", "file: " <> String.duplicate("p", 513)]))

      # The whole block past 4 KiB, every part within its own bound.
      wide = for i <- 1..8, do: "- #{i}" <> String.duplicate("𝄞", 98)

      past =
        block(tag, String.duplicate("𝄞", 200), wide ++ ["file: " <> String.duplicate("p", 512)])

      assert byte_size(past) > 4096
      refute ok.(past)
      assert byte_size(block(tag, "q", wide)) <= 4096
      assert ok.(block(tag, "q", wide))

      for text <- [
            # No choice, a repeated label, an empty label or question, two files,
            # a file before a choice, a line of anything else.
            block(tag, "q", []),
            block(tag, "q", ["- a", "- a"]),
            block(tag, "q", ["- "]),
            block(tag, "", ["- a"]),
            block(tag, "q", ["- a", "file: x", "file: y"]),
            block(tag, "q", ["file: x", "- a"]),
            block(tag, "q", ["- a", "", "- b"]),
            block(tag, "q", ["- a", "* b"]),
            # A question that reads as a choice or a file.
            block(tag, "- q", ["- a"]),
            # Text after the block, a block not at a line's start, no tag, a
            # tag with a space, no closing fence.
            block(tag) <> "\nmore",
            "see " <> block(tag),
            "```choices \nq\n- a\n```",
            "```choices trn_1 extra\nq\n- a\n```",
            "```choices #{tag}\nq\n- a",
            # A control or format character anywhere in it.
            block(tag, "q\r", ["- a"]),
            block(tag, "q", ["- a​"]),
            block(tag, "q", ["- a\u0007"])
          ] do
        assert Choices.parse(text) == :none, inspect(text)
      end

      # Only the last block counts, and an earlier one is text.
      assert {:ok, %{tag: "trn_2", prose: prose}} =
               Choices.parse(block("trn_1") <> "\n\n" <> block("trn_2"))

      assert prose == block("trn_1")
    end
  end

  describe "the marks a press is read between" do
    # Aqua reads a press's question and label between « and »
    # (`Aqua.Reader`), so neither may hold them, or two different presses
    # could read alike.
    test "a question or a label holding « or » makes the block text" do
      for {question, label} <- [
            {"Which «one»?", "Blue"},
            {"Which?", "Blue». The choice: «Green"},
            {"Which » now?", "Blue"},
            {"Which?", "«Blue"}
          ] do
        assert Choices.parse(block("trn_1", question, ["- " <> label])) == :none
      end

      assert {:ok, _} = Choices.parse(block("trn_1", "Which \"one\" — [sic]?", ["- <Blue>"]))
    end
  end

  describe "which row gives buttons" do
    test "Aqua's last brain-written row of its completed turn, on a model or a program; every " <>
           "other row shows as text",
         %{ctx: ctx, today: today} do
      model = turn!(ctx, today)
      _ = said!(ctx, today, model, "Let me look.")
      final = said!(ctx, today, model, "Pick one.\n\n" <> block(model.id))

      assert {:ok,
              %{
                row: final.id,
                prose: "Pick one.",
                question: "Which database should the export target?",
                choices: ["PostgreSQL", "SQLite"],
                file: nil,
                file_state: nil
              }} == Choices.read(ctx, final)

      program = turn!(ctx, today)
      row = said!(ctx, today, program, block(program.id), %{"brain_message" => "msg_1"})
      assert {:ok, %{row: row_id}} = Choices.read(ctx, row)
      assert row_id == row.id

      # A card never closes: the model's still reads after a later turn.
      assert {:ok, %{row: final_id}} = Choices.read(ctx, final)
      assert final_id == final.id

      # An intermediate message followed by an ordinary final line.
      turn = turn!(ctx, today)
      early = said!(ctx, today, turn, block(turn.id))
      _ = said!(ctx, today, turn, "Done.")
      assert Choices.read(ctx, early) == :none

      # The same with a `crew.ask` request between, as it writes one: no
      # turn of its own, its payload naming the asking turn.
      turn = turn!(ctx, today)
      early = said!(ctx, today, turn, block(turn.id))

      {:ok, _request} =
        Threads.append(actor(ctx), today.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          addressee: "planner",
          status: "pending",
          kind: "text",
          content: "Plan the export.",
          payload: %{"from_turn" => turn.id}
        })

      _ = said!(ctx, today, turn, "Asked the planner.")
      assert Choices.read(ctx, early) == :none

      # A text-only post a tool wrote, even as the turn's last row.
      turn = turn!(ctx, today)
      _ = said!(ctx, today, turn, "Posting it.")
      posted = said!(ctx, today, turn, block(turn.id), %{"post" => true})
      assert Choices.read(ctx, posted) == :none

      # A failed, cancelled or uncertain reply.
      for status <- ["failed", "cancelled", "uncertain"] do
        turn = turn!(ctx, today, status)
        assert Choices.read(ctx, said!(ctx, today, turn, block(turn.id))) == :none
      end

      # Another turn's tag, and a turn of no such id.
      turn = turn!(ctx, today)
      assert Choices.read(ctx, said!(ctx, today, turn, block(model.id))) == :none
      turn = turn!(ctx, today)
      assert Choices.read(ctx, said!(ctx, today, turn, block("trn_none"))) == :none

      # A person's line, a tool result, a system line and a member's reply,
      # each carrying the last turn's own tag.
      turn = turn!(ctx, today)

      for attrs <- [
            %{author: ctx.user_id, sent_by: "person", kind: "text"},
            %{author: Prima.Author.agent(), sent_by: "aqua", kind: "tool_result"},
            %{author: Prima.Author.system(), sent_by: "system", kind: "text"},
            %{
              author: Prima.Author.agent(),
              sent_by: "planner",
              kind: "text",
              payload: %{"step_id" => "stp_member"}
            }
          ] do
        {:ok, row} =
          Threads.append(
            actor(ctx),
            today.id,
            Map.merge(attrs, %{content: block(turn.id), turn_id: turn.id})
          )

        assert Choices.read(ctx, row) == :none, inspect(attrs)
      end

      # A row of a turn still running may yet be its final reply.
      running = turn!(ctx, today, "running")
      assert Choices.read(ctx, said!(ctx, today, running, block(running.id))) == :pending
    end

    test "a `file:` line reads whether Files lists the file, and keeps the choices either way",
         %{ctx: ctx, today: today} do
      :ok = Arca.put(actor(ctx), ["data", "aqua", "plans", "x-1-export.md"], "# Export\n")

      for {path, state} <- [
            {"data/aqua/plans/x-1-export.md", :present},
            {"data/aqua/plans/x-2-gone.md", :missing},
            {"data/nowhere/x.md", :missing},
            {"nowhere/x.md", :missing}
          ] do
        turn = turn!(ctx, today)
        row = said!(ctx, today, turn, block(turn.id, "Proceed?", ["- Proceed", "file: " <> path]))

        assert {:ok, %{choices: ["Proceed"], file: ^path, file_state: ^state}} =
                 Choices.read(ctx, row)
      end
    end
  end

  describe "a press" do
    test "is the person's line to Aqua, with the question and the label as data read on the " <>
           "server, whatever the label names",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      asked = "Which \"database\" — [sic]?"
      card = said!(ctx, today, turn, block(turn.id, asked, ["- Postgre<SQL>", "- @aqua, SQLite"]))

      assert {:ok, %{accepted: true, message_id: id, thread: landed, turn_id: opened}} =
               press(ctx, card, 1)

      assert landed == today.id
      {:ok, row} = Threads.get_message(actor(ctx), id)

      assert Map.take(row, [:thread_id, :author, :sent_by, :kind, :content, :turn_id, :addressee]) ==
               %{
                 thread_id: today.id,
                 author: ctx.user_id,
                 sent_by: "person",
                 kind: "text",
                 content: "@aqua, SQLite",
                 turn_id: opened,
                 addressee: "aqua"
               }

      assert Jason.decode!(row.payload) == %{
               "choice" => %{
                 "row" => card.id,
                 "index" => 1,
                 "question" => asked,
                 "label" => "@aqua, SQLite"
               }
             }

      assert {:ok, %{agent: "aqua", sent_by: "person"}} = Aqua.Tape.turn(ctx, opened)
    end

    test "of a card pressed already, of a card Aqua has moved on from, and of a card in a past " <>
           "day's thread each write the person's line and open Aqua's turn",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      {:ok, past} = Arca.Test.Days.thread(actor(ctx))
      old = turn!(ctx, past)
      yesterday = said!(ctx, past, old, block(old.id, "Then?", ["- Yes", "- No"]))

      presses = [
        {press(ctx, card, 0), card, 0},
        {press(ctx, card, 1), card, 1},
        {press(ctx, yesterday, 1), yesterday, 1}
      ]

      _later = turn!(ctx, today)
      presses = presses ++ [{press(ctx, card, 0), card, 0}]

      for {answer, source, index} <- presses do
        assert {:ok, %{message_id: id, thread: landed, turn_id: opened}} = answer
        assert landed == today.id
        {:ok, row} = Threads.get_message(actor(ctx), id)
        {:ok, block} = Choices.parse(source.content)

        assert %{thread_id: ^landed, sent_by: "person", turn_id: ^opened} = row

        assert Jason.decode!(row.payload)["choice"] == %{
                 "row" => source.id,
                 "index" => index,
                 "question" => block.question,
                 "label" => Enum.at(block.choices, index)
               }

        assert {:ok, %{agent: "aqua"}} = Aqua.Tape.turn(ctx, opened)
      end

      refute Enum.any?(Threads.messages(actor(ctx), past.id), &Choices.pressed/1)
    end

    test "names only a choice of Aqua's question: a row of no card, an index out of range, an " <>
           "unknown row and another athanor's card are refused",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      none = {:error, {:invalid_argument, "No question of Aqua's offers that choice."}}

      {:ok, line} =
        Threads.append(actor(ctx), today.id, %{
          author: ctx.user_id,
          sent_by: "person",
          content: block(turn.id)
        })

      {other, person} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
      other = %{other | athanor_id: Sanctum.Test.People.athanor!(person).id, origin: :interactive}
      {:ok, theirs} = Aqua.Day.current(other)
      their_turn = turn!(other, theirs)
      their_card = said!(other, theirs, their_turn, block(their_turn.id))
      before = Threads.messages(actor(ctx), today.id)

      assert press(ctx, card, 2) == none
      assert press(ctx, line, 0) == none
      assert press(ctx, %{id: "msg_none"}, 0) == none
      assert press(ctx, their_card, 0) == none
      assert Threads.messages(actor(ctx), today.id) == before
      refute Enum.any?(Threads.messages(actor(other), theirs.id), &Choices.pressed/1)
    end

    test "carries only its choice: a destination, a line, files, an empty file list, an " <>
           "agent, a model, a room or a message id beside it is refused before anything is written",
         %{ctx: ctx, today: today} do
      {:ok, past} = Arca.Test.Days.thread(actor(ctx))
      old = turn!(ctx, past)
      card = said!(ctx, past, old, block(old.id))
      {:ok, child} = Aqua.Tape.crew_thread(ctx, today.id, "builder")

      # Today's thread made anew by the first press of a day: none is made
      # for a refused one.
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^today.id),
          set: [day: Date.add(Aqua.Day.today(ctx), -1)]
        )

      before = {Threads.list(actor(ctx)), Arca.Repo.aggregate(Arca.Schemas.Message, :count)}

      ref = %{
        "filename" => "note.txt",
        "stored_name" => "0-note.txt",
        "media_type" => "text/plain",
        "size" => 3
      }

      for {key, value} <- [
            {"thread", child.id},
            {"thread", today.id},
            {"message", "PostgreSQL"},
            {"attachments", [ref]},
            {"attachments", []},
            {"agent", "aqua"},
            {"model", "claude-sonnet-5-5"},
            {"room", %{"shared_thread_id" => "thr_shared"}},
            {"id", Prima.UUID7.generate_id("msg")}
          ] do
        args = %{
          "action" => "send",
          "choice" => %{"row" => card.id, "index" => 0},
          key => value
        }

        refused = {:error, {:invalid_argument, "A press carries only its choice."}}
        assert Tool.handle("thread", ctx, args) == refused, inspect({key, value})
        assert Sanctum.Gate.call_external("thread", ctx, args) == refused
      end

      assert {Threads.list(actor(ctx)), Arca.Repo.aggregate(Arca.Schemas.Message, :count)} ==
               before
    end

    test "lands where its card is: a workspace card in its workspace, a daily card in today's " <>
           "thread; the declaration takes a press of its choice and a client id alone",
         %{ctx: ctx, today: today} do
      workspace =
        %Arca.Schemas.Thread{}
        |> Arca.Schemas.Thread.changeset(%{
          id: Prima.UUID7.generate_id("thread"),
          athanor_id: ctx.athanor_id,
          kind: "workspace",
          workspace_state: "done",
          title: "Export",
          created_by: ctx.user_id
        })
        |> Arca.Repo.insert!()

      turn = turn!(ctx, workspace)
      card = said!(ctx, workspace, turn, block(turn.id))
      assert {:ok, %{thread: landed, turn_id: opened}} = press(ctx, card, 0)
      assert landed == workspace.id
      assert {:ok, %{agent: "aqua", thread_id: ^landed}} = Aqua.Tape.turn(ctx, opened)

      daily = turn!(ctx, today)
      today_card = said!(ctx, today, daily, block(daily.id))

      today_id = today.id

      assert {:ok, %{thread: ^today_id}} =
               Sanctum.Gate.call_external("thread", ctx, %{
                 "action" => "send",
                 "choice" => %{"row" => today_card.id, "index" => 1},
                 "client_id" => "snd_gate"
               })

      # A send that is no press still names its line.
      assert {:error,
              {:invalid_argument, "A send that is no press says a line or carries files."}} =
               Tool.handle("thread", ctx, %{"action" => "send", "thread" => today.id})
    end

    test "a press retried across midnight answers its first receipt and writes once",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))

      assert {:ok, %{replayed: false, message_id: id, thread: landed}} =
               press(ctx, card, 0, "snd_boundary")

      # The day turns: the thread it landed in is yesterday's now.
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^today.id),
          set: [day: Date.add(Aqua.Day.today(ctx), -1)]
        )

      assert {:ok, %{replayed: true, message_id: ^id, thread: ^landed}} =
               press(ctx, card, 0, "snd_boundary")

      assert [_one] =
               Arca.Repo.all(
                 from(m in Arca.Schemas.Message,
                   where: m.athanor_id == ^ctx.athanor_id and m.client_id == "snd_boundary"
                 )
               )
    end

    test "a plain send under a press's client id is another send, refused, nothing replayed",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      assert {:ok, %{replayed: false}} = press(ctx, card, 0, "snd_same")

      assert {:error, :client_id_reused} =
               Tool.handle("thread", ctx, %{
                 "action" => "send",
                 "thread" => today.id,
                 "client_id" => "snd_same",
                 "message" => "PostgreSQL"
               })

      assert [%{content: "PostgreSQL"}] =
               for(
                 m <- Threads.messages(actor(ctx), today.id),
                 m.sent_by == "person" and m.content == "PostgreSQL",
                 do: m
               )
    end

    test "a resend under its client id is the same press; that id on another choice, or on " <>
           "another card whose label reads alike, is refused and replays nothing",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id, "First?", ["- Blue", "- Green"]))
      other = turn!(ctx, today)
      second = said!(ctx, today, other, block(other.id, "Second?", ["- Blue", "- Amber"]))

      assert {:ok, %{message_id: id, replayed: false}} = press(ctx, card, 0, "snd_1")
      assert {:ok, %{message_id: ^id, replayed: true}} = press(ctx, card, 0, "snd_1")
      assert {:error, :client_id_reused} = press(ctx, card, 1, "snd_1")
      assert {:error, :client_id_reused} = press(ctx, second, 0, "snd_1")

      assert [%{id: ^id} = only] =
               for(m <- Threads.messages(actor(ctx), today.id), Choices.pressed(m) != nil, do: m)

      assert Choices.pressed(only)["row"] == card.id
    end
  end

  describe "a send bound for a daily thread across midnight" do
    # The day turns `days` back for `thread`: what was today is that many
    # days ago, and the next send of today makes today's thread anew.
    defp aged!(ctx, thread, days) do
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          set: [day: Date.add(Aqua.Day.today(ctx), -days)]
        )

      thread
    end

    defp line(ctx, text, client_id),
      do:
        Tool.handle("thread", ctx, %{
          "action" => "send",
          "message" => text,
          "client_id" => client_id
        })

    defp under(ctx, client_id),
      do:
        Arca.Repo.all(
          from(m in Arca.Schemas.Message,
            where: m.athanor_id == ^ctx.athanor_id and m.client_id == ^client_id
          )
        )

    test "a plain line under yesterday's press id is refused and writes nothing",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      assert {:ok, %{message_id: id}} = press(ctx, card, 0, "snd_press")

      aged!(ctx, today, 1)
      assert line(ctx, "PostgreSQL", "snd_press") == {:error, :client_id_reused}
      assert [%{id: ^id}] = under(ctx, "snd_press")

      # The press's own line is the label; the refused one wrote none.
      assert [] =
               Arca.Repo.all(
                 from(m in Arca.Schemas.Message,
                   where:
                     m.athanor_id == ^ctx.athanor_id and m.sent_by == "person" and
                       m.content == "PostgreSQL" and m.id != ^id
                 )
               )
    end

    test "three days on, with a plain line tried under its id between, the press retried " <>
           "answers its first receipt and leaves one row under the id",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      assert {:ok, %{message_id: id, thread: landed}} = press(ctx, card, 0, "snd_press")

      aged!(ctx, today, 1)
      _ = line(ctx, "PostgreSQL", "snd_press")

      # A second day turns, past a daily thread made in between.
      aged!(ctx, today, 2)
      {:ok, between} = Aqua.Day.current(ctx)
      aged!(ctx, between, 1)

      assert {:ok, %{replayed: true, message_id: ^id, thread: ^landed}} =
               press(ctx, card, 0, "snd_press")

      assert [%{id: ^id}] = under(ctx, "snd_press")
    end

    test "a plain line retried across midnight answers its first receipt and writes once",
         %{ctx: ctx, today: today} do
      assert {:ok, %{message_id: id, thread: landed, replayed: false}} =
               line(ctx, "hello", "snd_plain")

      assert landed == today.id
      aged!(ctx, today, 1)

      assert {:ok, %{message_id: ^id, thread: ^landed, replayed: true}} =
               line(ctx, "hello", "snd_plain")

      assert [%{id: ^id}] = under(ctx, "snd_plain")
    end

    test "a plain line under a new client id after midnight lands in today's thread",
         %{ctx: ctx, today: today} do
      assert {:ok, %{thread: first}} = line(ctx, "hello", "snd_one")
      assert first == today.id
      aged!(ctx, today, 1)
      assert {:ok, %{thread: second, replayed: false}} = line(ctx, "hello again", "snd_two")
      assert {:ok, %{id: ^second, day: day}} = Aqua.Day.current(ctx)
      assert second != first and day == Aqua.Day.today(ctx)
    end
  end

  describe "a send that is no press" do
    test "carrying files and no message is accepted; with neither it is refused",
         %{ctx: ctx, today: today} do
      mid = Prima.UUID7.generate_id("msg")

      assert {:ok, %{attachments: refs}} =
               Tool.handle("thread", ctx, %{
                 "action" => "attach",
                 "thread" => today.id,
                 "message_id" => mid,
                 "files" => [
                   %{
                     "filename" => "note.txt",
                     "media_type" => "text/plain",
                     "data" => Base.encode64("notes")
                   }
                 ]
               })

      assert {:ok, %{accepted: true, message_id: ^mid}} =
               Tool.handle("thread", ctx, %{
                 "action" => "send",
                 "thread" => today.id,
                 "id" => mid,
                 "attachments" => refs
               })

      refused =
        {:error, {:invalid_argument, "A send that is no press says a line or carries files."}}

      for args <- [%{}, %{"message" => "  "}, %{"attachments" => []}] do
        assert Tool.handle(
                 "thread",
                 ctx,
                 Map.merge(%{"action" => "send", "thread" => today.id}, args)
               ) ==
                 refused
      end
    end
  end
end
