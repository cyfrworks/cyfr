# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ChoicesTest do
  @moduledoc """
  A question's choices as buttons, on Aqua's own rows: the block's one
  grammar, the one row of a turn that gives buttons, when a card closes,
  and a press through `thread.send` as the person, read again on the
  server and written as data. A member's card, delivered through the
  crew, is `Aqua.CrewTest`'s; the rows the real brains write are
  `Aqua.ProgramTest`'s.
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

  defp press(ctx, thread_id, row, index, client_id \\ nil) do
    Tool.handle(
      "thread",
      ctx,
      %{
        "action" => "send",
        "thread" => thread_id,
        "message" => "anything the browser says",
        "choice" => %{"row" => row.id, "index" => index}
      }
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

  describe "which row gives buttons" do
    test "the completed soul turn's last brain-written row, on a model or a program; every other " <>
           "row shows as text",
         %{ctx: ctx, today: today} do
      # A model's final row, and a program's, each naming what it is.
      model = turn!(ctx, today)
      _ = said!(ctx, today, model, "Let me look.")
      final = said!(ctx, today, model, "Pick one.\n\n" <> block(model.id))

      assert {:ok,
              %{
                row: final.id,
                prose: "Pick one.",
                question: "Which database should the export target?",
                choices: ["PostgreSQL", "SQLite"],
                asker: "aqua",
                open?: true,
                file: nil,
                file_state: nil
              }} == Choices.read(ctx, final)

      program = turn!(ctx, today)
      row = said!(ctx, today, program, block(program.id), %{"brain_message" => "msg_1"})
      assert {:ok, %{asker: "aqua", open?: true}} = Choices.read(ctx, row)

      # The model's card closed when the program's turn came after it.
      assert {:ok, %{open?: false}} = Choices.read(ctx, final)

      # An intermediate message followed by an ordinary final line.
      turn = turn!(ctx, today)
      early = said!(ctx, today, turn, block(turn.id))
      _ = said!(ctx, today, turn, "Done.")
      assert Choices.read(ctx, early) == :none

      # A text-only post a tool wrote, before the turn completed, is no
      # brain's reply, even as its last row.
      turn = turn!(ctx, today)
      _ = said!(ctx, today, turn, "Posting it.")
      posted = said!(ctx, today, turn, block(turn.id), %{"post" => true})
      assert Choices.read(ctx, posted) == :none

      # A failed reply, a cancelled one.
      for status <- ["failed", "cancelled", "uncertain"] do
        turn = turn!(ctx, today, status)
        assert Choices.read(ctx, said!(ctx, today, turn, block(turn.id))) == :none
      end

      # Another turn's tag, and a turn of no such id.
      turn = turn!(ctx, today)
      assert Choices.read(ctx, said!(ctx, today, turn, block(model.id))) == :none
      turn = turn!(ctx, today)
      assert Choices.read(ctx, said!(ctx, today, turn, block("trn_none"))) == :none

      # A person's message, a tool result and a system line carrying the
      # last turn's own tag.
      turn = turn!(ctx, today)

      for attrs <- [
            %{author: ctx.user_id, sent_by: "person", kind: "text"},
            %{author: Prima.Author.agent(), sent_by: "aqua", kind: "tool_result"},
            %{author: Prima.Author.system(), sent_by: "system", kind: "text"}
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

    test "a `file:` line reads whether Files has the file, and keeps the choices either way",
         %{ctx: ctx, today: today} do
      :ok = Arca.put(actor(ctx), ["data", "aqua", "plans", "x-1-export.md"], "# Export\n")

      for {path, state} <- [
            {"data/aqua/plans/x-1-export.md", :present},
            {"data/aqua/plans/x-2-gone.md", :missing},
            {"nowhere/x.md", :missing}
          ] do
        turn = turn!(ctx, today)
        row = said!(ctx, today, turn, block(turn.id, "Proceed?", ["- Proceed", "file: " <> path]))

        assert {:ok, %{choices: ["Proceed"], file: ^path, file_state: ^state, open?: true}} =
                 Choices.read(ctx, row)
      end
    end
  end

  describe "a press" do
    test "is the person's line to Aqua, with the question, the label and the asker as data read " <>
           "on the server; a second press of the card is refused",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      asked = "Which \"database\" — «quoted» [sic]?"
      card = said!(ctx, today, turn, block(turn.id, asked, ["- Postgre«SQL»", "- @aqua, SQLite"]))
      assert {:ok, %{open?: true}} = Choices.read(ctx, card)

      assert {:ok, %{accepted: true, message_id: id, thread: landed, turn_id: opened}} =
               press(ctx, today.id, card, 1)

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
                 "label" => "@aqua, SQLite",
                 "asker" => "aqua"
               }
             }

      assert {:ok, %{agent: "aqua", sent_by: "person"}} = Aqua.Tape.turn(ctx, opened)

      # The card is closed, and so is every way to press it again.
      assert {:ok, %{open?: false}} = Choices.read(ctx, card)

      for index <- [0, 1] do
        assert press(ctx, today.id, card, index) ==
                 {:error, {:conflict, "This question is no longer open."}}
      end
    end

    test "names only a card's row and a choice it has: a row of no card, an index out of range, " <>
           "and a row of another thread are refused",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      closed = {:error, {:conflict, "This question is no longer open."}}

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

      {:ok, line} =
        Threads.append(actor(ctx), today.id, %{
          author: ctx.user_id,
          sent_by: "person",
          content: block(turn.id)
        })

      assert press(ctx, today.id, card, 2) == closed
      assert press(ctx, today.id, line, 0) == closed
      assert press(ctx, today.id, %{id: "msg_none"}, 0) == closed
      assert press(ctx, workspace.id, card, 0) == closed
      assert Enum.map(Threads.messages(actor(ctx), workspace.id), & &1.id) == []
      assert {:ok, %{open?: true}} = Choices.read(ctx, card)
    end

    test "a retry of an accepted press by its client id answers the same press",
         %{ctx: ctx, today: today} do
      turn = turn!(ctx, today)
      card = said!(ctx, today, turn, block(turn.id))
      assert {:ok, %{message_id: id, replayed: false}} = press(ctx, today.id, card, 0, "snd_1")
      assert {:ok, %{message_id: ^id, replayed: true}} = press(ctx, today.id, card, 0, "snd_1")

      assert press(ctx, today.id, card, 1, "snd_1") ==
               {:error, {:conflict, "This question is no longer open."}}
    end

    test "a card in a past day's daily thread is closed, and a press of it is refused",
         %{ctx: ctx, today: today} do
      {:ok, past} = Arca.Test.Days.thread(actor(ctx))
      turn = turn!(ctx, past)
      card = said!(ctx, past, turn, block(turn.id))
      assert {:ok, %{open?: false, choices: ["PostgreSQL", "SQLite"]}} = Choices.read(ctx, card)
      before = Threads.messages(actor(ctx), today.id)

      assert press(ctx, past.id, card, 0) ==
               {:error, {:conflict, "This question is no longer open."}}

      assert Threads.messages(actor(ctx), today.id) == before
    end
  end
end
