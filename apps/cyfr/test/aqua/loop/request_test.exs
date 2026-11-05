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
      "native_search" => "auto"
    }

    tools = Request.tool_definitions(policy)

    names = Enum.map(tools, & &1["name"])
    assert names == ["files", "notes", "ui", "request_setup"]

    files = Enum.find(tools, &(&1["name"] == "files"))
    assert files["parameters"]["properties"]["action"]["enum"] == ["read", "write"]
    assert files["description"] =~ "Actions write need the person's approval"
    assert Map.has_key?(files["parameters"]["properties"], "path")

    notes = Enum.find(tools, &(&1["name"] == "notes"))
    assert notes["parameters"]["properties"]["action"]["enum"] == ["keep", "read"]

    # External tools ride under their wire name.
    [ext] =
      Request.tool_definitions(%{},
        external: [
          %{name: "github:search", description: "Search", input_schema: %{"type" => "object"}}
        ]
      )
      |> Enum.filter(&(&1["name"] == "github__search"))

    assert ext["description"] =~ "approval"
  end

  test "catalog tools alone, and an instruction as the person's last word" do
    assert [%{"name" => "notes"} = notes] = Request.catalog_tools(%{"notes.keep" => "auto"})
    assert get_in(notes, ["parameters", "properties", "action", "enum"]) == ["keep"]
    assert Request.catalog_tools(%{"files.read" => "auto", "notes.keep" => "deny"}) == []

    user = %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
    tool = %{"role" => "tool", "content" => [%{"type" => "tool_result", "tool_call_id" => "c"}]}

    assert [%{"role" => "user", "content" => [_, %{"text" => "now"}]}] =
             Request.instruct([user], "now")

    assert [^tool, %{"role" => "user", "content" => [%{"text" => "now"}]}] =
             Request.instruct([tool], "now")

    assert [%{"role" => "user"}] = Request.instruct([], "now")
  end

  describe "the accounts a launch may name" do
    defp connection(tools) do
      tools
      |> Enum.find(&(&1["name"] == "execution"))
      |> get_in(["parameters", "properties", "connection", "description"])
    end

    test "are listed per app with their names and the default, never an entry" do
      accounts = %{
        apps: [
          {"formula:local.mailer", ["Personal", "Work"]},
          {"reagent:local.db", ["Supabase 2"]}
        ],
        truncated?: false
      }

      text =
        connection(Request.tool_definitions(%{"execution.run" => "ask"}, accounts: accounts))

      assert text =~ "omit `connection` for its default account"
      assert text =~ ~s[formula:local.mailer ("Personal", "Work")]
      assert text =~ ~s[reagent:local.db ("Supabase 2")]
      refute text =~ "vlt_"
      refute text =~ "and more"

      # Nothing listed says so, and still names the default.
      none =
        connection(
          Request.tool_definitions(%{"execution.run" => "auto"},
            accounts: %{apps: [], truncated?: false}
          )
        )

      assert none =~ "omit `connection` for its default account"
      assert none =~ "No app binds a named account"

      # Without the turn's list the declared description stands.
      declared = connection(Request.tool_definitions(%{"execution.run" => "ask"}))
      assert declared =~ "a run started outside a chain asks its profile's own calls for it"
      refute declared =~ "Apps with named accounts"
    end

    test "list at most fifty apps, and a cut list says how many more" do
      apps =
        for n <- 1..53, do: {"reagent:local.app-#{String.pad_leading("#{n}", 2, "0")}", ["Work"]}

      text =
        connection(
          Request.tool_definitions(%{"execution.run" => "ask"},
            accounts: %{apps: apps, truncated?: false}
          )
        )

      assert text =~ "reagent:local.app-50"
      refute text =~ "reagent:local.app-51"
      assert text =~ "and 3 more."

      # Heads read cut short: more may stand, uncounted.
      cut =
        connection(
          Request.tool_definitions(%{"execution.run" => "ask"},
            accounts: %{apps: Enum.take(apps, 2), truncated?: true}
          )
        )

      assert cut =~ "reagent:local.app-02"
      assert cut =~ "and more."
    end
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

  describe "crew rows" do
    defp crew(seq, sent_by, content, fields) do
      struct(row(seq, "text", if(sent_by == "person", do: "usr_a", else: @agent), content), [
        {:sent_by, sent_by} | fields
      ])
    end

    test "the reading agent's own speech is its own; a request, a reply, a notice and another agent's words are said to it" do
      rows = [
        crew(1, "person", "what next?", addressee: "aqua"),
        crew(2, "aqua", "Asking the planner.", payload: Jason.encode!(%{"step_id" => "s1"})),
        crew(3, "aqua", "plan it", addressee: "planner", status: "pending"),
        crew(4, "person", "check the logs", addressee: "builder", status: "answered"),
        crew(5, "builder", "Logs are clean.",
          addressee: "person",
          reply_to: "msg_4",
          outcome: "done"
        ),
        crew(6, "planner", "Write the plan?",
          addressee: "aqua",
          reply_to: "msg_3",
          outcome: "needs_you"
        )
      ]

      assert [
               %{"role" => "user", "content" => [%{"text" => "what next?"}]},
               %{"role" => "assistant", "content" => [%{"text" => "Asking the planner."}]},
               %{"role" => "user", "content" => said}
             ] = Request.messages(rows, me: "aqua")

      texts = Enum.map(said, & &1["text"])

      # The soul's own request is its tool call's to show, not a row's.
      refute Enum.any?(texts, &(&1 =~ "plan it"))
      assert Enum.any?(texts, &(&1 =~ "usr_a asked builder (request msg_4, answered)"))
      assert Enum.any?(texts, &(&1 =~ "builder replied to request msg_4: done]\nLogs are clean."))
      assert Enum.any?(texts, &(&1 =~ "planner needs the person on request msg_3"))

      # In the member's thread the soul's task is said to the member.
      assert [%{"role" => "user", "content" => [%{"text" => "[aqua]\nplan it"}]}] =
               Request.messages([crew(1, "aqua", "plan it", addressee: "planner")], me: "planner")
    end

    test "a request the reader made still shows once a compaction summarized its call away, while it waits" do
      rows = [
        crew(1, "aqua", "plan it", addressee: "planner", status: "pending"),
        crew(2, "aqua", "check it", addressee: "builder", status: "answered"),
        row(3, "compaction", @system, "Earlier work.", %{
          "first_kept_seq" => 4,
          "summarized_through_seq" => 3
        }),
        crew(4, "person", "and now?", addressee: "aqua")
      ]

      [%{"role" => "user", "content" => blocks}] = Request.messages(rows, me: "aqua")
      texts = Enum.map(blocks, & &1["text"])

      assert [
               "[Summary of the thread so far]\nEarlier work.",
               "[Request msg_1 to planner, still waiting on its reply]\nplan it",
               "and now?"
             ] = texts
    end
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
                 %{"text" => "[Summary of the thread so far]\nWe discussed x."},
                 %{"text" => "new question"},
                 %{"text" => "## Read from a shared thread\n\nBob: hi"}
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

  test "attachments land on the turn's own message, not the oldest one in the transcript" do
    image = %{"type" => "image", "media_type" => "image/png", "data" => "…"}

    rows = [
      row(1, "text", "usr_a", "something from last week"),
      row(2, "text", @agent, "an answer"),
      row(3, "text", "usr_a", "what is in this picture?")
    ]

    # Without the id there is nothing to aim at and the oldest message takes
    # it, which is the whole defect in a thread with history.
    assert [%{"content" => [_, ^image]}, _, %{"content" => [_]}] =
             Request.messages(rows, attachments: [image])

    assert [%{"content" => [_]}, _, %{"content" => [_, ^image]}] =
             Request.messages(rows, attachments: [image], task_message_id: "msg_3")
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

  test "a session rides the request, and an option rides only when the brain declares it, of its kind" do
    effort = %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]}
    caps = %{options: [effort]}

    request =
      Request.build(
        model: "m",
        messages: [],
        capabilities: caps,
        session: "s1",
        options: %{"effort" => "high"}
      )

    assert request["session"] == "s1"
    assert request["options"] == %{"effort" => "high"}

    for {options, member} <- [
          {%{"effort" => "max"}, "options.effort"},
          {%{"temperature" => 1}, "options.temperature"}
        ] do
      error =
        assert_raise ArgumentError, fn ->
          Request.build(model: "m", messages: [], capabilities: caps, options: options)
        end

      assert error.message =~ member
    end

    # A brain that declares none takes none.
    assert_raise ArgumentError, fn ->
      Request.build(model: "m", messages: [], options: %{"effort" => "high"})
    end

    request = Request.build(model: "m", messages: [], options: %{})
    refute Map.has_key?(request, "session")
    refute Map.has_key?(request, "options")
  end

  # The excerpt block is what `attach/3` places last; `without_excerpt/1`
  # takes it back in both shapes and nothing else.
  describe "without_excerpt/1" do
    test "removes the trailing excerpt block, or the message it alone made" do
      prefix = "## Read from a shared thread\n\nthey said hi"

      appended = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "hi"},
              %{"type" => "text", "text" => prefix}
            ]
          }
        ]
      }

      assert %{"messages" => [%{"content" => [%{"text" => "hi"}]}]} =
               Aqua.Loop.Request.without_excerpt(appended)

      alone = %{
        "messages" => [
          %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => prefix}]}
        ]
      }

      assert %{"messages" => [%{"role" => "assistant"}]} =
               Aqua.Loop.Request.without_excerpt(alone)

      # A person's own line that happens to open that way is theirs.
      theirs = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "## Read from a shared thread\n\nmine"},
              %{"type" => "text", "text" => "then"}
            ]
          }
        ]
      }

      assert Aqua.Loop.Request.without_excerpt(theirs) == theirs

      plain = %{
        "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]
      }

      assert Aqua.Loop.Request.without_excerpt(plain) == plain
    end
  end
end
