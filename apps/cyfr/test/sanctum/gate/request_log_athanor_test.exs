# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.RequestLogAthanorTest do
  @moduledoc """
  The request log files a call's output under the athanor the call ran
  in only when the output came from that athanor: a read whose answer
  names another athanor leaves its operation, its status and the
  `cross_athanor` marker, never the body, so the members of the focused
  athanor read nothing of an athanor they may not open. The caller's own
  answer is unchanged, and a read of the focused athanor keeps its output.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Context, Gate, RequestLog}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

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
    {:ok, u} = Users.upsert_from_provider(%{id: "local|idp|note-#{n}", provider: "local"})

    {:ok, mine} =
      Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me#{n}",
        owner_user_id: u.id,
        created_by: u.id
      })

    {:ok, _} = Users.set_personal_athanor(u, mine.id)
    # The owner's seat in their own athanor, as `ensure_personal_athanor/1`
    # mints it in production.
    {:ok, _} = Members.create(%{user_id: u.id, athanor_id: mine.id})
    {:ok, group} = Athanors.create_group(u.id, "Trip #{n}")

    alice = %{Sanctum.TestContext.local(:prism) | user_id: u.id, athanor_id: group.id}
    {:ok, home} = Context.focus(alice, mine.id)

    {:ok, bob_user} =
      Users.upsert_from_provider(%{id: "local|idp|bob-#{n}", provider: "local"})

    {:ok, _} = Members.create(%{user_id: bob_user.id, athanor_id: group.id})

    bob =
      Context.build(
        user_id: bob_user.id,
        athanor_id: group.id,
        permissions: [:storage_read],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, alice: alice, home: home, mine: mine, group: group, bob: bob}
  end

  defp notes_rows(bob) do
    assert {:ok, %{logs: rows}} =
             Gate.call_external("mcp_log", bob, %{"action" => "list", "tool" => "notes"})

    rows
  end

  test "a personal note read from a group stays out of the group's log", %{
    alice: alice,
    home: home,
    mine: mine,
    bob: bob
  } do
    body = "Private travel plan: arriving in Lisbon on Thursday"
    assert {:ok, _} = Aqua.Notes.keep(home, "private-travel", body)
    assert {:error, :not_found} = Context.focus(bob, mine.id)

    # The caller's own answer is the note.
    assert {:ok, %{content: ^body}} =
             Gate.call_external("notes", alice, %{
               "action" => "read",
               "name" => "private-travel",
               "scope" => "mine"
             })

    assert {:ok, %{matches: [%{snippet: snippet}]}} =
             Gate.call_external("notes", alice, %{
               "action" => "search",
               "query" => "Thursday",
               "scope" => "everywhere"
             })

    assert snippet =~ "Lisbon"

    # The rows keep the caller's own arguments, and nothing the other
    # athanor answered.
    rows = notes_rows(bob)
    refute inspect(rows) =~ "Lisbon"

    for action <- ["read", "search"] do
      assert [row] = Enum.filter(rows, &(&1.action == action))
      assert row.status == "success"
      assert row.output == %{"redacted" => "cross_athanor"}
    end
  end

  test "a read of the focused athanor keeps its output in the log", %{alice: alice, bob: bob} do
    body = "Group plan: meet at the station at nine"
    assert {:ok, _} = Aqua.Notes.keep(alice, "meeting", body)

    assert {:ok, %{content: ^body}} =
             Gate.call_external("notes", alice, %{"action" => "read", "name" => "meeting"})

    assert [row] = Enum.filter(notes_rows(bob), &(&1.action == "read"))
    assert row.status == "success"
    assert inspect(row.output) =~ "meet at the station"
    refute Map.has_key?(row.output, "redacted")
  end

  test "the completion columns name the redaction only for another athanor's output", %{
    group: group,
    mine: mine,
    alice: alice
  } do
    ours = %{name: "n", content: "here", athanor_id: group.id}
    theirs = %{matches: [%{name: "n", snippet: "there", athanor_id: mine.id}]}
    athanor_row = %{id: mine.id, name: "Me"}
    member_list = %{athanor: mine.id, members: [%{email: "x@example.com"}]}

    assert %{status: "success", output: kept} = RequestLog.closed(alice, {:ok, ours}, %{})
    assert kept =~ "here"

    for other <- [theirs, athanor_row, member_list] do
      assert %{status: "success", output: ~s({"redacted":"cross_athanor"})} =
               RequestLog.closed(alice, {:ok, other}, %{})
    end

    # A clock or a source inside an answer is read by its fields, and the
    # row is still written.
    clocked = %{id: group.id, created_at: DateTime.utc_now()}

    assert %{status: "success", output: clocked_kept} =
             RequestLog.closed(alice, {:ok, clocked}, %{})

    assert clocked_kept =~ group.id

    sourced = %{id: mine.id, created_at: DateTime.utc_now(), sources: [Prima.Source.new(:filed)]}

    assert %{status: "success", output: ~s({"redacted":"cross_athanor"})} =
             RequestLog.closed(alice, {:ok, sourced}, %{})

    # Prose that merely starts like an id is a body, not a locator.
    prose = %{content: "ath_ is how an athanor id starts", athanor_id: group.id}
    assert %{output: prose_kept} = RequestLog.closed(alice, {:ok, prose}, %{})
    assert prose_kept =~ "how an athanor id starts"
  end
end
