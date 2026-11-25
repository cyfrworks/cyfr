# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.FacadeTest do
  @moduledoc """
  The assistant's door for callers outside it is an exact roster: an
  entry added without a roster change fails here. Each group of entries
  answers what the internal it names answers.
  """

  use ExUnit.Case, async: true

  @roster [
    action_title: 2,
    at_work: 2,
    attachment_blob_path: 3,
    attachment_limits: 0,
    attachment_refs: 1,
    attachments_as_kept: 2,
    brain_options: 2,
    browser_turned_off: 0,
    describe_note_result: 1,
    known_program: 2,
    mark_read: 3,
    model_status: 2,
    models: 1,
    models: 2,
    note_pinned?: 1,
    offerings: 3,
    pin_max_bytes: 0,
    pinned_note_page: 1,
    program_listing: 2,
    providers: 1,
    put_reading: 2,
    room_excerpt: 2,
    roster: 1,
    stale_consent_refs: 1,
    steps: 2,
    steps: 3,
    stream_abandoned: 2,
    stream_add: 2,
    stream_advance: 2,
    stream_landed: 2,
    stream_new: 0,
    stream_texts: 1,
    strip_attachment_name: 1,
    thread_state: 2,
    threads: 2,
    today: 1,
    tool_title: 1,
    virtual_tool_catalog: 0,
    workspace: 2
  ]

  test "the root answers exactly its roster" do
    exported =
      Aqua.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  test "the brains a setup offers are Aqua.Models'" do
    outside = Sanctum.Context.build(user_id: "usr_outside")

    assert Aqua.providers(outside) == Aqua.Models.providers(outside)
    assert {:error, :forbidden} = Aqua.providers(outside)
  end

  test "a tool family reads as its declared title, a virtual tool as its family's" do
    assert Aqua.tool_title("notes") == "Notes"
    assert Aqua.tool_title("files") == Sanctum.VirtualTools.table()["files"].title
    assert Aqua.tool_title("no-such-tool") == "no-such-tool"
  end

  test "attachment bounds and names are Aqua.Attachments'" do
    assert Aqua.attachment_limits() == Aqua.Attachments.limits()
    assert Aqua.strip_attachment_name("a\u0000b\nc.txt") == "abc.txt"

    ref = %{"filename" => "a.txt", "stored_name" => "0-a.txt"}
    assert {:ok, path} = Aqua.attachment_blob_path("thr_1", "msg_1", ref)
    assert {:ok, ^path} = Aqua.Attachments.blob_path("thr_1", "msg_1", ref)
    assert :error = Aqua.attachment_blob_path("thr_1", "msg_1", %{"filename" => "a.txt"})

    # A row that holds no file reads no storage and answers none.
    row = %Arca.Schemas.Message{id: "msg_1", thread_id: "thr_1", payload: nil}
    ctx = Sanctum.TestContext.local()
    assert Aqua.attachments_as_kept(ctx, row) == Aqua.Attachments.as_kept(ctx, row)
    assert Aqua.attachments_as_kept(ctx, row) == []
  end

  test "the virtual catalog is Prima's" do
    assert Aqua.virtual_tool_catalog() == Sanctum.VirtualTools.action_kinds()
    assert Aqua.virtual_tool_catalog() == Aqua.Hands.list_for_panel()
  end

  test "Aqua's own actions read as what each does" do
    {:ok, {_module, %{operations: operations}}} = Map.fetch(Sanctum.Catalog.operations(), "aqua")
    titles = Map.new(operations, &{&1.action, Aqua.action_title("aqua", &1.action)})

    assert titles == %{
             "list" => "List Aqua, its crew and its guides",
             "get" => "Read Aqua, a crew member or a guide",
             "create" => "Add a crew member",
             "update" => "Change Aqua or a crew member",
             "delete" => "Remove a crew member",
             "reset" => "Restore Aqua's shipped files",
             "status" => "Where each of Aqua's files came from",
             "skill_list" => "List scrolls",
             "skill_get" => "Read a scroll",
             "skill_create" => "Write a new scroll",
             "skill_update" => "Change a scroll",
             "skill_delete" => "Remove a scroll"
           }
  end

  test "a permission reads by the words its action is declared with, never its id" do
    {:ok, {_module, %{operations: operations}}} = Map.fetch(Sanctum.Catalog.operations(), "notes")
    %{description: words} = Enum.find(operations, &(&1.action == "pin"))
    assert Aqua.action_title("notes", "pin") == words
    assert Aqua.action_title("files", "read") == "Files: read"

    for {tool, actions} <- Aqua.virtual_tool_catalog(), {action, _kind} <- actions do
      refute Aqua.action_title(tool, action) == "#{tool}.#{action}"
    end
  end

  test "the pinned page's bounds and names are Aqua.Notes'" do
    assert Aqua.pin_max_bytes() == Aqua.Notes.pin_max_bytes()

    for name <- ["about-you", "notes", ""],
        do: assert(Aqua.note_pinned?(name) == Aqua.Notes.pinned?(name))

    assert Aqua.describe_note_result(:not_a_write) == nil
  end

  test "a stream kept through the facade is the one Aqua.Loop.Stream keeps" do
    delta = %{
      fence: 2,
      source: "soul",
      step_id: "stp_1",
      ordinal: 0,
      seq: {1, 1},
      text: "hello",
      role: "soul"
    }

    through_facade =
      Aqua.stream_new()
      |> Aqua.stream_advance(2)
      |> Aqua.stream_add(delta)
      |> Aqua.stream_add(%{delta | seq: {1, 2}, text: " there"})

    assert [%{step_id: "stp_1", text: "hello there"}] = Aqua.stream_texts(through_facade)

    marker = %{fence: 2, source: "soul", step_id: "stp_1", ordinal: 0}

    assert Aqua.stream_abandoned(through_facade, marker) ==
             Aqua.Loop.Stream.abandoned(through_facade, marker)

    assert Aqua.stream_texts(Aqua.stream_abandoned(through_facade, marker)) == []

    assert Aqua.stream_landed(through_facade, %{kind: "note"}) == through_facade
  end
end
