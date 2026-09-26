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
    approval_scope_string: 1,
    attachment_blob_path: 3,
    attachment_limits: 0,
    attachment_refs: 1,
    auto_permitted?: 2,
    consent_state: 1,
    consent_state: 2,
    describe_note_result: 1,
    discard_attachments: 4,
    model_capabilities: 5,
    model_status: 2,
    models: 1,
    note_pinned?: 1,
    parse_approval_scope: 1,
    pin_max_bytes: 0,
    pinned_note_page: 1,
    room_excerpt: 2,
    roster: 1,
    stale_consent_refs: 1,
    store_attachments: 4,
    stream_abandoned: 2,
    stream_add: 2,
    stream_advance: 2,
    stream_landed: 2,
    stream_new: 0,
    stream_texts: 1,
    strip_attachment_name: 1,
    thread_state: 2,
    tool_kind: 2,
    virtual_tool_catalog: 0
  ]

  test "the root answers exactly its roster" do
    exported =
      Aqua.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__info__, :module_info] end)
      |> Enum.sort()

    assert exported == @roster
  end

  test "approval scopes parse and print as Aqua.ApprovalScope does" do
    for scope <- ["thread", "always", "never", :once, "bogus", nil] do
      assert Aqua.parse_approval_scope(scope) == Aqua.ApprovalScope.parse(scope)
    end

    for scope <- Aqua.ApprovalScope.all() do
      assert Aqua.approval_scope_string(scope) == Aqua.ApprovalScope.to_string(scope)
    end
  end

  test "attachment bounds and names are Aqua.Attachments'" do
    assert Aqua.attachment_limits() == Aqua.Attachments.limits()
    assert Aqua.strip_attachment_name("a\u0000b\nc.txt") == "abc.txt"

    ref = %{"filename" => "a.txt", "stored_name" => "0-a.txt"}
    assert {:ok, path} = Aqua.attachment_blob_path("thr_1", "msg_1", ref)
    assert {:ok, ^path} = Aqua.Attachments.blob_path("thr_1", "msg_1", ref)
    assert :error = Aqua.attachment_blob_path("thr_1", "msg_1", %{"filename" => "a.txt"})
  end

  test "an action's kind and its auto rule are Aqua.Kinds', the virtual catalog Prima's" do
    assert Aqua.tool_kind("files", "read") == :read
    assert Aqua.tool_kind("files", "delete") == :destructive
    assert Aqua.tool_kind("server:tool", "anything") == :external
    assert Aqua.auto_permitted?("files", "write")
    refute Aqua.auto_permitted?("files", "delete")
    refute Aqua.auto_permitted?("server:tool", "anything")

    assert Aqua.virtual_tool_catalog() == Grimoire.VirtualTools.action_kinds()
    assert Aqua.virtual_tool_catalog() == Aqua.Hands.list_for_panel()
  end

  test "the pinned page's bounds and names are Aqua.Notes'" do
    assert Aqua.pin_max_bytes() == Aqua.Notes.pin_max_bytes()

    for name <- ["about-you", "about-us", "notes", ""],
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
