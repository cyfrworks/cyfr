# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.RequestLogAthanorTest do
  @moduledoc """
  The request log files a call's output under the athanor the call ran
  in only when the output came from that athanor: a read whose answer
  names another athanor leaves its operation, its status and the
  `cross_athanor` marker, never the body, so the focused athanor's log
  keeps nothing of another athanor. The caller's own answer is unchanged,
  and a read of the focused athanor keeps its output.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Gate, RequestLog}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "notes_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)

    n = System.unique_integer([:positive])
    {:ok, u} = Sanctum.Test.People.linked(%{id: "local|idp|note-#{n}", provider: "local"})

    # The person's own athanor, where they work, which their admission made.
    mine = Sanctum.Test.People.athanor!(u)

    # Another person's own athanor, whose answers alice's log keeps out.
    {:ok, bob_user} =
      Sanctum.Test.People.linked(%{id: "local|idp|bob-#{n}", provider: "local"})

    bobs = Sanctum.Test.People.athanor!(bob_user)
    alice = %{Sanctum.TestContext.local(:prism) | user_id: u.id, athanor_id: mine.id}

    {:ok, alice: alice, mine: mine, bobs: bobs}
  end

  defp notes_rows(ctx) do
    assert {:ok, %{logs: rows}} =
             Gate.call_external("mcp_log", ctx, %{"action" => "list", "tool" => "notes"})

    rows
  end

  test "a read of the focused athanor keeps its output in the log", %{alice: alice} do
    body = "Plan: meet at the station at nine"
    assert {:ok, _} = Aqua.Notes.keep(alice, "meeting", body)

    assert {:ok, %{content: ^body}} =
             Gate.call_external("notes", alice, %{"action" => "read", "name" => "meeting"})

    assert [row] = Enum.filter(notes_rows(alice), &(&1.action == "read"))
    assert row.status == "success"
    assert inspect(row.output) =~ "meet at the station"
    refute Map.has_key?(row.output, "redacted")
  end

  test "the completion columns name the redaction only for another athanor's output", %{
    bobs: bobs,
    mine: mine,
    alice: alice
  } do
    ours = %{name: "n", content: "here", athanor_id: mine.id}
    theirs = %{matches: [%{name: "n", snippet: "there", athanor_id: bobs.id}]}
    athanor_row = %{id: bobs.id, name: "Bob"}
    member_list = %{athanor: bobs.id, members: [%{email: "x@example.com"}]}

    assert %{status: "success", output: kept} = RequestLog.closed(alice, {:ok, ours}, %{})
    assert kept =~ "here"

    for other <- [theirs, athanor_row, member_list] do
      assert %{status: "success", output: ~s({"redacted":"cross_athanor"})} =
               RequestLog.closed(alice, {:ok, other}, %{})
    end

    # A clock or a source inside an answer is read by its fields, and the
    # row is still written.
    clocked = %{id: mine.id, created_at: DateTime.utc_now()}

    assert %{status: "success", output: clocked_kept} =
             RequestLog.closed(alice, {:ok, clocked}, %{})

    assert clocked_kept =~ mine.id

    sourced = %{id: bobs.id, created_at: DateTime.utc_now(), sources: [Prima.Source.new(:filed)]}

    assert %{status: "success", output: ~s({"redacted":"cross_athanor"})} =
             RequestLog.closed(alice, {:ok, sourced}, %{})

    # Prose that merely starts like an id is a body, not a locator.
    prose = %{content: "ath_ is how an athanor id starts", athanor_id: mine.id}
    assert %{output: prose_kept} = RequestLog.closed(alice, {:ok, prose}, %{})
    assert prose_kept =~ "how an athanor id starts"
  end
end
