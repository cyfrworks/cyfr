# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.RequestTest do
  @moduledoc """
  The request the loop sends: tools from the effective policy, and the
  projection shaped for the contract — a step's reply and calls as one
  assistant message with the stored typed blocks, results on a tool
  message with the call's name, a compaction in place of the rows before
  its boundary, a dangling call answered, the excerpt transient.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Request
  alias Arca.Schemas.Message

  defp row(seq, kind, author, content, payload \\ nil) do
    %Message{
      id: "msg_#{seq}",
      seq: seq,
      kind: kind,
      author: author,
      content: content,
      payload: payload && Jason.encode!(payload)
    }
  end

  @agent Message.agent_author()
  @system Message.system_author()

  test "tools come from the policy: offered when auto or ask, enum restricted, asks said" do
    policy = %{
      "files.read" => "auto",
      "files.write" => "ask",
      "files.delete" => "deny",
      "notes.read" => "auto",
      "notes.keep" => "ask",
      "http.get" => "deny",
      "builder.*" => "auto",
      "native_search" => "auto"
    }

    tools =
      Request.tool_definitions(policy, roles: [%{"name" => "builder", "title" => "Builder"}])

    names = Enum.map(tools, & &1["name"])
    assert names == ["files", "notes", "builder", "ui", "request_setup"]

    files = Enum.find(tools, &(&1["name"] == "files"))
    assert files["parameters"]["properties"]["action"]["enum"] == ["read", "write"]
    assert files["description"] =~ "Actions write need the person's approval"
    assert Map.has_key?(files["parameters"]["properties"], "path")

    notes = Enum.find(tools, &(&1["name"] == "notes"))
    assert notes["parameters"]["properties"]["action"]["enum"] == ["keep", "read"]

    builder = Enum.find(tools, &(&1["name"] == "builder"))
    assert builder["parameters"]["required"] == ["task"]

    # A role rides only for the soul, external tools under their wire name.
    refute "builder" in Enum.map(
             Request.tool_definitions(policy, roles: [%{"name" => "builder"}], soul?: false),
             & &1["name"]
           )

    [ext] =
      Request.tool_definitions(%{},
        external: [
          %{name: "github:search", description: "Search", input_schema: %{"type" => "object"}}
        ]
      )
      |> Enum.filter(&(&1["name"] == "github__search"))

    assert ext["description"] =~ "approval"
  end

  test "the projection is shaped for the contract" do
    rows = [
      row(1, "text", "usr_a", "@aqua read a.txt"),
      row(2, "text", @agent, "Reading.", %{"step_id" => "s1"}),
      row(3, "tool_call", @agent, "files", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "tool" => "files",
        "action" => "read",
        "arguments" => %{"action" => "read", "path" => "a.txt"},
        "provider_data" => %{"thought_signature" => "sig"},
        "step_id" => "s1"
      }),
      row(4, "tool_result", @system, "line 1", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "step_id" => "s1"
      }),
      row(5, "approval", @agent, "Write?", %{"intent" => %{}}),
      row(6, "error", @system, "boom"),
      row(7, "text", @agent, "Done.", %{"step_id" => "s2"}),
      row(8, "text", "usr_b", "thanks")
    ]

    messages = Request.messages(rows, multi_author?: true, names: %{"usr_a" => "Ann"})

    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "Ann: @aqua read a.txt"}]
             },
             %{
               "role" => "assistant",
               "content" => [%{"type" => "text", "text" => "Reading."}, call]
             },
             %{"role" => "tool", "content" => [result]},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Done."}]},
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "usr_b: thanks"}]}
           ] = messages

    assert call == %{
             "type" => "tool_call",
             "id" => "call_1",
             "name" => "files",
             "arguments" => %{"action" => "read", "path" => "a.txt"},
             "provider_data" => %{"thought_signature" => "sig"}
           }

    assert result == %{
             "type" => "tool_result",
             "tool_call_id" => "call_1",
             "name" => "files",
             "content" => "line 1",
             "is_error" => false
           }
  end

  test "repeated call ids across steps stay distinct, and a dangling call is answered" do
    rows = [
      row(1, "text", "usr_a", "go"),
      row(2, "tool_call", @agent, "files", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "arguments" => %{},
        "step_id" => "s1"
      }),
      row(3, "tool_result", @system, "ok", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "step_id" => "s1"
      }),
      row(4, "tool_call", @agent, "files", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "arguments" => %{},
        "step_id" => "s2"
      }),
      row(5, "turn_aborted", @system, "restart")
    ]

    messages = Request.messages(rows)

    assert [
             _,
             %{"role" => "assistant"},
             %{"role" => "tool"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => [synthetic]},
             %{"role" => "user"}
           ] = messages

    assert synthetic["tool_call_id"] == "call_1" and synthetic["is_error"] == true
    assert synthetic["content"] =~ "partially executed"
  end

  test "a compaction stands in for the rows before its boundary, and the excerpt is transient" do
    rows = [
      row(1, "text", "usr_a", "old"),
      row(2, "text", @agent, "older reply", %{"step_id" => "s0"}),
      row(3, "compaction", @system, "We discussed x.", %{
        "first_kept_seq" => 4,
        "summarized_through_seq" => 3
      }),
      row(4, "text", "usr_a", "new question")
    ]

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"text" => "[Summary of the conversation so far]\nWe discussed x."},
                 %{"text" => "new question"},
                 %{"text" => "## Read from the room\n\nBob: hi"}
               ]
             }
           ] = Request.messages(rows, excerpt: "Bob: hi")

    # Attachments ride on the initiating message, first user message.
    [%{"content" => content}] =
      Request.messages([row(1, "text", "usr_a", "see")],
        attachments: [%{"type" => "image", "media_type" => "image/png", "data" => "…"}]
      )

    assert [%{"type" => "text"}, %{"type" => "image"}] = content
  end

  test "the request carries the ceiling and the provider tools the catalyst offers" do
    caps = %{max_output_tokens: 4_000, default_max_tokens: 8_000, provider_tools: ["web_search"]}

    request =
      Request.build(model: "m", messages: [], tools: [], capabilities: caps, native_search?: true)

    assert request["max_tokens"] == 4_000
    assert request["provider_tools"] == ["web_search"]

    assert Request.build(
             model: "m",
             messages: [],
             capabilities: %{provider_tools: []},
             native_search?: true
           )["provider_tools"] == []

    assert Request.build(model: "m", messages: [])["max_tokens"] == 16_384
  end
end
