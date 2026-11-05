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
    assert OutboxRecord.kinds() == ~w(schedule_outcome crew_request crew_reply)
    assert OutboxRecord.source_kinds() == ~w(schedule_occurrence message turn)
    assert OutboxRecord.reply_outcomes() == ~w(done failed cancelled uncertain needs_you)
    assert OutboxRecord.max_output_bytes() == 64 * 1024
    assert OutboxRecord.max_reply_bytes() == 32 * 1024
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

  test "a stored row reads back for every kind, and not outside the rosters" do
    for record <- [OutboxRecord.crew_request(request()), OutboxRecord.crew_reply(reply())] do
      {:ok, text} = OutboxRecord.encode_snapshot(record)
      row = record |> Map.from_struct() |> Map.put(:snapshot, text)

      assert OutboxRecord.from_stored(row) == {:ok, record}
      assert OutboxRecord.from_stored(%{row | kind: "crew_note"}) == {:error, :unreadable}
      assert OutboxRecord.from_stored(%{row | source_kind: "room"}) == {:error, :unreadable}
    end
  end
end
