# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.OutboxRecordTest do
  @moduledoc """
  The closed rosters and the crew records: a hand-off and a reply are
  each one record of their source at its revision, with exactly the
  snapshot the kind names, a reply's text cut on a character boundary at
  its bound, and a record outside the shape refused before it is made.
  A stored row reads back for every kind, and not for a kind or source
  kind outside the rosters.
  """

  use ExUnit.Case, async: true

  alias Prima.OutboxRecord
  alias Prima.Source

  @at ~U[2026-11-05 12:00:00.000001Z]

  defp request(attrs \\ %{}) do
    Map.merge(
      %{
        athanor_id: "ath_1",
        request_id: "msg_req",
        inserted_at: @at,
        room_thread_id: "thr_room",
        member: "reviewer",
        task: "read the diff",
        tools: ["files", "web"],
        options: %{"effort" => "high"},
        person_id: "usr_1",
        origin: :interactive
      },
      attrs
    )
  end

  defp reply(attrs \\ %{}) do
    Map.merge(
      %{
        athanor_id: "ath_1",
        turn_id: "turn_1",
        ended_at: @at,
        asking_thread_id: "thr_room",
        request_ids: ["msg_req", "msg_steer"],
        member: "reviewer",
        outcome: "done",
        text: "looks right",
        person_id: "usr_1",
        origin: :schedule
      },
      attrs
    )
  end

  test "the rosters are closed" do
    assert OutboxRecord.kinds() ==
             ~w(schedule_outcome crew_request crew_reply workspace_open workspace_report brain_forget)

    assert OutboxRecord.source_kinds() == ~w(schedule_occurrence message turn thread)
    assert OutboxRecord.reply_outcomes() == ~w(done failed cancelled uncertain needs_you)
    assert OutboxRecord.report_outcomes() == ~w(done needs_you error)
    assert OutboxRecord.max_report_files() == 10
    assert OutboxRecord.max_output_bytes() == 64 * 1024
    assert OutboxRecord.max_reply_bytes() == 32 * 1024
  end

  test "an opening is a record of its workspace thread at the opening's instant" do
    assert %OutboxRecord{
             source_kind: "thread",
             source_id: "thr_work",
             source_revision: "2026-11-05T12:00:00.000001Z",
             athanor_id: "ath_1",
             kind: "workspace_open",
             snapshot:
               %{
                 "workspace_id" => "thr_work",
                 "opening_id" => "msg_open",
                 "person_id" => "usr_1",
                 "origin" => "interactive"
               } = snapshot
           } =
             OutboxRecord.workspace_open(%{
               athanor_id: "ath_1",
               workspace_id: "thr_work",
               opening_id: "msg_open",
               inserted_at: @at,
               person_id: "usr_1",
               origin: :interactive
             })

    assert map_size(snapshot) == 4
  end

  defp report(attrs) do
    Map.merge(
      %{
        athanor_id: "ath_1",
        workspace_id: "thr_work",
        title: "Moon report",
        turn_id: "turn_1",
        moved_at: @at,
        outcome: "done",
        summary: "written",
        attachments: [%{"message_id" => "msg_post", "stored_name" => "0-chart.png"}],
        sources: [Source.outside("moon.example"), Source.thread("thr_daily")],
        person_id: "usr_1",
        origin: :interactive
      },
      attrs
    )
  end

  test "a report is a record of its workspace thread at the move, with the turn's sources" do
    for outcome <- OutboxRecord.report_outcomes() do
      assert %OutboxRecord{
               source_kind: "thread",
               source_id: "thr_work",
               source_revision: "2026-11-05T12:00:00.000001Z",
               kind: "workspace_report",
               snapshot:
                 %{
                   "workspace_id" => "thr_work",
                   "title" => "Moon report",
                   "turn_id" => "turn_1",
                   "outcome" => ^outcome,
                   "summary" => "written",
                   "truncated" => false,
                   "attachments" => [
                     %{"message_id" => "msg_post", "stored_name" => "0-chart.png"}
                   ],
                   "person_id" => "usr_1",
                   "origin" => "interactive"
                 } = snapshot
             } = record = OutboxRecord.workspace_report(report(%{outcome: outcome}))

      assert OutboxRecord.report_sources(record) ==
               [Source.outside("moon.example"), Source.thread("thr_daily")]

      refute Map.has_key?(snapshot, "approval_id")
    end

    assert %{snapshot: %{"approval_id" => "apr_1"}} =
             OutboxRecord.workspace_report(report(%{outcome: "needs_you", approval_id: "apr_1"}))

    assert %{snapshot: %{"truncated" => true, "summary" => cut}} =
             OutboxRecord.workspace_report(report(%{summary: String.duplicate("é", 20_000)}))

    assert byte_size(cut) <= 32 * 1024 and String.valid?(cut)
  end

  test "a report carries only files of posts, ten at most" do
    assert_raise ArgumentError, fn ->
      OutboxRecord.workspace_report(report(%{attachments: [%{"path" => "notes/x.md"}]}))
    end

    eleven = for n <- 1..11, do: %{"message_id" => "msg_#{n}", "stored_name" => "0-x"}

    assert_raise FunctionClauseError, fn ->
      OutboxRecord.workspace_report(report(%{attachments: eleven}))
    end

    for outcome <- ~w(failed cancelled) do
      assert_raise FunctionClauseError, fn ->
        OutboxRecord.workspace_report(report(%{outcome: outcome}))
      end
    end
  end

  test "only the server's error report may name no turn" do
    assert %{snapshot: %{"turn_id" => nil, "outcome" => "error"}} =
             OutboxRecord.workspace_report(report(%{turn_id: nil, outcome: "error"}))

    for outcome <- OutboxRecord.report_outcomes() -- ["error"] do
      assert_raise FunctionClauseError, fn ->
        OutboxRecord.workspace_report(report(%{turn_id: nil, outcome: outcome}))
      end
    end

    assert_raise FunctionClauseError, fn ->
      OutboxRecord.workspace_report(report(%{turn_id: "", outcome: "error"}))
    end
  end

  test "a hand-off is a record of its request row, with the snapshot its kind names" do
    assert %OutboxRecord{
             source_kind: "message",
             source_id: "msg_req",
             source_revision: "2026-11-05T12:00:00.000001Z",
             athanor_id: "ath_1",
             kind: "crew_request",
             snapshot:
               %{
                 "room_thread_id" => "thr_room",
                 "request_id" => "msg_req",
                 "member" => "reviewer",
                 "task" => "read the diff",
                 "tools" => ["files", "web"],
                 "options" => %{"effort" => "high"},
                 "person_id" => "usr_1",
                 "origin" => "interactive"
               } = snapshot
           } = OutboxRecord.crew_request(request())

    assert map_size(snapshot) == 8

    # The whole arsenal leaves `tools` out of the stored text.
    whole = OutboxRecord.crew_request(request(%{tools: nil, options: %{}}))
    assert {:ok, text} = OutboxRecord.encode_snapshot(whole)
    refute Map.has_key?(Jason.decode!(text), "tools")
    assert Jason.decode!(text)["options"] == %{}
  end

  test "a reply is a record of its turn, with the snapshot its kind names" do
    for outcome <- OutboxRecord.reply_outcomes() do
      assert %OutboxRecord{
               source_kind: "turn",
               source_id: "turn_1",
               source_revision: "2026-11-05T12:00:00.000001Z",
               athanor_id: "ath_1",
               kind: "crew_reply",
               snapshot:
                 %{
                   "asking_thread_id" => "thr_room",
                   "request_ids" => ["msg_req", "msg_steer"],
                   "member" => "reviewer",
                   "outcome" => ^outcome,
                   "text" => "looks right",
                   "truncated" => false,
                   "person_id" => "usr_1",
                   "origin" => "schedule"
                 } = snapshot
             } = OutboxRecord.crew_reply(reply(%{outcome: outcome}))

      assert map_size(snapshot) == 8
    end
  end

  test "a needs_you reply names its card's approval, and no other reply does" do
    assert %{snapshot: %{"approval_id" => "apr_1"} = snapshot} =
             OutboxRecord.crew_reply(reply(%{outcome: "needs_you", approval_id: "apr_1"}))

    assert map_size(snapshot) == 9

    for outcome <- OutboxRecord.reply_outcomes() -- ["needs_you"] do
      %{snapshot: snapshot} =
        OutboxRecord.crew_reply(reply(%{outcome: outcome, approval_id: "apr_1"}))

      refute Map.has_key?(snapshot, "approval_id"), outcome
    end
  end

  test "a reply's text is cut at its bound on a character boundary, and says so" do
    max = OutboxRecord.max_reply_bytes()

    at_bound = String.duplicate("a", max)

    assert %{snapshot: %{"text" => ^at_bound, "truncated" => false}} =
             OutboxRecord.crew_reply(reply(%{text: at_bound}))

    # A two-byte character straddles the bound: the cut drops all of it.
    straddling = String.duplicate("a", max - 1) <> "é" <> "tail"

    assert %{snapshot: %{"text" => cut, "truncated" => true}} =
             OutboxRecord.crew_reply(reply(%{text: straddling}))

    assert cut == String.duplicate("a", max - 1)
    assert String.valid?(cut)
  end

  test "a record outside the shape is refused before it is made" do
    for bad <- [
          %{athanor_id: ""},
          %{request_id: ""},
          %{room_thread_id: nil},
          %{member: ""},
          %{task: ""},
          %{tools: "files"},
          %{options: nil},
          %{person_id: ""},
          %{origin: "interactive"},
          %{inserted_at: "2026-11-05"}
        ] do
      assert_raise FunctionClauseError, fn -> OutboxRecord.crew_request(request(bad)) end
    end

    assert_raise ArgumentError, fn -> OutboxRecord.crew_request(request(%{tools: [""]})) end

    for bad <- [
          %{turn_id: ""},
          %{asking_thread_id: ""},
          %{request_ids: []},
          %{member: nil},
          %{outcome: "succeeded"},
          %{outcome: :done},
          %{text: nil},
          %{person_id: ""},
          %{origin: :unknown},
          %{ended_at: nil}
        ] do
      assert_raise FunctionClauseError, fn -> OutboxRecord.crew_reply(reply(bad)) end
    end

    assert_raise ArgumentError, fn -> OutboxRecord.crew_reply(reply(%{request_ids: [1]})) end
  end

  defp forget(attrs \\ %{}),
    do:
      Map.merge(
        %{
          athanor_id: "ath_1",
          thread_id: "thr_1",
          row_id: "mcp_1",
          session: "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
          generation: 3
        },
        attrs
      )

  test "a removal owed is a record of its thread at the generation the session was held under" do
    assert OutboxRecord.brain_forget(forget()) == %OutboxRecord{
             source_kind: "thread",
             source_id: "thr_1",
             source_revision: "3",
             athanor_id: "ath_1",
             kind: "brain_forget",
             snapshot: %{
               "thread_id" => "thr_1",
               "row_id" => "mcp_1",
               "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
               "generation" => 3
             }
           }

    for bad <- [
          %{athanor_id: ""},
          %{thread_id: nil},
          %{row_id: nil},
          %{session: ""},
          %{generation: -1},
          %{generation: "3"}
        ] do
      assert_raise FunctionClauseError, fn -> OutboxRecord.brain_forget(forget(bad)) end
    end
  end

  test "a stored row reads back for every kind, and not outside the rosters" do
    for record <- [
          OutboxRecord.crew_request(request()),
          OutboxRecord.crew_reply(reply()),
          OutboxRecord.brain_forget(forget())
        ] do
      {:ok, text} = OutboxRecord.encode_snapshot(record)
      row = record |> Map.from_struct() |> Map.put(:snapshot, text)

      assert OutboxRecord.from_stored(row) == {:ok, record}
      assert OutboxRecord.from_stored(%{row | kind: "crew_note"}) == {:error, :unreadable}
      assert OutboxRecord.from_stored(%{row | source_kind: "room"}) == {:error, :unreadable}
    end
  end
end
