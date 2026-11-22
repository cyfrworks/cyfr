# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ReaderTest do
  @moduledoc """
  The one wording of a thread row for a model: each kind as the reader's
  own, said to it or none, a person's post no model took, and an opening's
  citations only from what the caller handed over.
  """

  use ExUnit.Case, async: true

  alias Aqua.Reader
  alias Arca.Schemas.Message

  @agent Message.agent_author()
  @system Message.system_author()

  defp row(fields) do
    struct!(
      %Message{
        id: "msg_1",
        thread_id: "thr_1",
        author: "usr_1",
        sent_by: "person",
        content: "hi"
      },
      fields
    )
  end

  defp reading(fields \\ %{}) do
    Map.merge(
      %{
        me: "aqua",
        open: ["trn_open"],
        refused: [],
        named?: false,
        refs: %{},
        removed: %{},
        display: &Map.get(%{"usr_1" => "Ada"}, &1, &1)
      },
      fields
    )
  end

  test "each kind of row has one reading" do
    titled = fn fields -> Jason.encode!(Map.put(fields, "title", "Moon")) end

    table = [
      {row([]), {:said, "hi"}},
      {row(author: @agent, sent_by: "aqua"), {:own, "hi"}},
      {row(author: @agent, sent_by: "aqua", payload: ~s({"post":true})), :none},
      {row(author: @agent, sent_by: "aqua", addressee: "builder", status: "pending"), :none},
      {row(author: @agent, sent_by: "builder"), {:said, "[builder]\nhi"}},
      {row(addressee: "builder", status: "answered"),
       {:said, "[Ada asked builder (request msg_1, answered)]\nhi"}},
      {row(author: @agent, sent_by: "builder", reply_to: "msg_0", outcome: "failed"),
       {:said, "[builder replied to request msg_0: failed]\nhi"}},
      {row(author: @system), {:said, "[A line from the server, not the person]\nhi"}},
      {row(author: @system, payload: ~s({"schedule":{"id":"sched_1","name":"Morning"}})),
       {:said, "[The schedule \"Morning\" (sched_1) fired with its line]\nhi"}},
      {row(kind: "nudge", author: @system, sent_by: "system"),
       {:said, "[A line from the server, not the person]\nhi"}},
      {row(kind: "opening", payload: titled.(%{"asked_by" => "usr_1"})),
       {:said, "[Ada asked, in this workspace thread \"Moon\" (thr_1)]\nhi"}},
      {row(kind: "pointer", workspace_id: "thr_w", payload: titled.(%{})),
       {:said, "[The workspace thread \"Moon\" (thr_w) was opened or asked again from here]"}},
      {row(kind: "report", workspace_id: "thr_w", payload: titled.(%{"outcome" => "error"})),
       {:said,
        "[Report from the workspace thread \"Moon\" (thr_w): error, Aqua could not run it]\nhi"}},
      {row(kind: "turn_aborted", author: @system),
       {:said,
        "[The server restarted while the assistant was working; tools may have partially executed. hi]"}}
    ]

    for {row, read} <- table, do: assert(Reader.read(row, reading()) == read)

    for kind <- ~w(error system tool_call tool_result compaction page_call page_result) do
      assert Reader.read(row(kind: kind, author: @system), reading()) == :none
    end
  end

  test "a person's post of a turn that is over reads untaken when no step carried it or its " <>
         "delivery was refused, and only then" do
    untaken =
      {:said,
       "[Ada posted this and it was not taken: its turn ended before any model read it. " <>
         "Act on it only if they ask again]\nhi"}

    over = [turn_id: "trn_over"]
    carried = over ++ [carried_by: "stp_1"]

    assert Reader.read(row(over), reading()) == untaken
    assert Reader.read(row(carried), reading(%{refused: ["msg_1"]})) == untaken

    taken = {:said, "Ada: hi"}
    named = reading(%{named?: true})
    assert Reader.read(row(carried), named) == taken
    assert Reader.read(row([]), named) == taken
    assert Reader.read(row(turn_id: "trn_open"), named) == taken

    request = row(over ++ [addressee: "builder", status: "pending"])

    assert Reader.read(request, named) ==
             {:said, "[Ada asked builder (request msg_1, pending)]\nhi"}

    server = row(over ++ [author: @system])
    assert Reader.read(server, named) == {:said, "[A line from the server, not the person]\nhi"}
  end

  test "a reading with no roles says the reader's own by who said it, and a result as an answer" do
    nobody = reading(%{me: :nobody})

    assert Reader.read(row(author: @agent, sent_by: "aqua"), nobody) == {:said, "[aqua]\nhi"}

    assert Reader.read(row(author: @agent, sent_by: "aqua", payload: ~s({"post":true})), nobody) ==
             {:said, "[aqua]\nhi"}

    assert Reader.read(
             row(author: @agent, sent_by: "aqua", addressee: "builder", status: "pending"),
             nobody
           ) == {:said, "[aqua asked builder (request msg_1, pending)]\nhi"}

    assert Reader.read(row(kind: "error", author: @system), nobody) ==
             {:said, "[A line from the server, not the person]\nhi"}

    assert Reader.read(
             row(kind: "tool_result", author: @system, payload: ~s({"name":"files"})),
             nobody
           ) == {:said, "Your call files answered: hi"}
  end

  test "a cited question that was refused keeps its warning" do
    opening = row(kind: "opening", payload: ~s({"title":"Moon","refs":["msg_q"]}))
    question = row(id: "msg_q", turn_id: "trn_over", carried_by: "stp_1", content: "book it")

    assert {:said, read} =
             Reader.read(opening, reading(%{refs: %{"msg_q" => question}, refused: ["msg_q"]}))

    assert read =~
             "[Post msg_q of the daily thread, by Ada]\n[Ada posted this and it was not taken"
  end

  test "an opening expands the citations it is handed alone and never names a deleted file" do
    moon = %{"filename" => "moon.png", "stored_name" => "0-moon.png"}
    notes = %{"filename" => "notes.txt", "stored_name" => "1-notes.txt"}

    opening =
      row(
        kind: "opening",
        payload:
          Jason.encode!(%{
            "title" => "Moon",
            "refs" => ["msg_kept", "msg_gone"],
            "attachments" => [moon, notes]
          })
      )

    cited = row(id: "msg_kept", author: @agent, sent_by: "aqua", content: "full tonight")

    assert Reader.read(
             opening,
             reading(%{refs: %{"msg_kept" => cited}, removed: %{"msg_1" => [moon]}})
           ) ==
             {:said,
              "[Ada asked, in this workspace thread \"Moon\" (thr_1)]\nhi" <>
                "\n\n[Post msg_kept of the daily thread, by aqua]\nfull tonight" <>
                "\n\n[Files carried in: notes.txt]"}
  end
end
