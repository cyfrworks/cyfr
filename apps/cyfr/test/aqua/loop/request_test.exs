# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.RequestTest do
  @moduledoc """
  The request the loop sends: tools from the member's offered set, and the
  projection shaped for the contract — a step's reply and calls as one
  assistant message with the stored typed blocks, results on a tool
  message with the call's name, a compaction in place of the rows before
  its boundary, a dangling call answered, the excerpt transient.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.{Planner, Request}
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

  test "tools come from the offered set: a tool per offered action, its enum those, and no approval said" do
    tools = ~w(files.read files.write notes.read notes.keep browser.open native_search)

    # The person's browser setting off turns the browser's action off: the
    # browser is no tool of the request; on, it is one.
    off = Request.tool_definitions(Aqua.Offered.resolve(tools, {:ok, false}))
    on = Request.tool_definitions(Aqua.Offered.resolve(tools, {:ok, true}))

    assert Enum.map(off, & &1["name"]) == ["files", "notes", "ui", "request_setup"]
    assert Enum.map(on, & &1["name"]) == ["files", "browser", "notes", "ui", "request_setup"]

    files = Enum.find(off, &(&1["name"] == "files"))
    assert files["parameters"]["properties"]["action"]["enum"] == ["read", "write"]
    assert Map.has_key?(files["parameters"]["properties"], "path")

    notes = Enum.find(off, &(&1["name"] == "notes"))
    assert notes["parameters"]["properties"]["action"]["enum"] == ["keep", "read"]

    # A catalog tool's description is the catalog's own, whatever its
    # actions do: nothing is said of an approval or a pause.
    {:ok, declared} = Sanctum.Catalog.get_tool("notes")
    assert notes["description"] == declared["description"]

    for tool <- on,
        do: refute(tool["description"] =~ ~r/approval|pauses the turn/, tool["name"])

    # External tools ride under their wire name, with their server's own
    # description.
    [ext] =
      Request.tool_definitions(%{},
        external: [
          %{name: "github:search", description: "Search", input_schema: %{"type" => "object"}}
        ]
      )
      |> Enum.filter(&(&1["name"] == "github__search"))

    assert ext["description"] == "Search"
  end

  test "a launch's description is the catalog's own, with no word of an approval, and its actions are those offered" do
    execution =
      %{"execution.run" => "offered", "execution.logs" => "offered"}
      |> Request.tool_definitions()
      |> Enum.find(&(&1["name"] == "execution"))

    {:ok, declared} = Sanctum.Catalog.get_tool("execution")
    assert execution["description"] == declared["description"]
    refute execution["description"] =~ "approval"
    assert Enum.sort(execution["parameters"]["properties"]["action"]["enum"]) == ["logs", "run"]
  end

  test "catalog tools alone, and an instruction as the person's last word" do
    assert [%{"name" => "notes"} = notes] = Request.catalog_tools(%{"notes.keep" => "offered"})
    assert get_in(notes, ["parameters", "properties", "action", "enum"]) == ["keep"]
    # A hand is no catalog tool, and a browser action turned off is none.
    assert Request.catalog_tools(%{"files.read" => "offered", "browser.open" => "off"}) == []

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
        connection(Request.tool_definitions(%{"execution.run" => "offered"}, accounts: accounts))

      assert text =~ "omit `connection` for its default account"
      assert text =~ ~s[formula:local.mailer ("Personal", "Work")]
      assert text =~ ~s[reagent:local.db ("Supabase 2")]
      refute text =~ "vlt_"
      refute text =~ "and more"

      # Nothing listed says so, and still names the default.
      none =
        connection(
          Request.tool_definitions(%{"execution.run" => "offered"},
            accounts: %{apps: [], truncated?: false}
          )
        )

      assert none =~ "omit `connection` for its default account"
      assert none =~ "No app binds a named account"

      # Without the turn's list the declared description stands.
      declared = connection(Request.tool_definitions(%{"execution.run" => "offered"}))
      assert declared =~ "a run started outside a chain asks its profile's own calls for it"
      refute declared =~ "Apps with named accounts"
    end

    test "list at most fifty apps, and a cut list says how many more" do
      apps =
        for n <- 1..53, do: {"reagent:local.app-#{String.pad_leading("#{n}", 2, "0")}", ["Work"]}

      text =
        connection(
          Request.tool_definitions(%{"execution.run" => "offered"},
            accounts: %{apps: apps, truncated?: false}
          )
        )

      assert text =~ "reagent:local.app-50"
      refute text =~ "reagent:local.app-51"
      assert text =~ "and 3 more."

      # Heads read cut short: more may stand, uncounted.
      cut =
        connection(
          Request.tool_definitions(%{"execution.run" => "offered"},
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
      row(6, "error", @system, "boom"),
      row(7, "text", @agent, "Done.", %{"step_id" => "s2"}),
      row(8, "text", "usr_b", "thanks")
    ]

    messages = Request.messages(rows, %{}, multi_author?: true, names: %{"usr_a" => "Ann"})

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

  test "a page's call and its answer, a host's step, are in no model's request, ordinary or " <>
         "compaction, beside a model's own call that is" do
    model_call =
      row(2, "tool_call", @agent, "files", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "tool" => "files",
        "action" => "read",
        "arguments" => %{"action" => "read", "path" => "a.txt"},
        "step_id" => "s1"
      })

    # The rows a page's step writes (`Aqua.PageCalls.row/1`, and its close).
    page_call =
      row(4, "page_call", @agent, "execution.run", %{
        "tool_call_id" => "pcl_page",
        "name" => "execution.run",
        "arguments" => %{"reference" => "reagent:local.app:1.0.0", "input" => %{}},
        "tool" => "execution",
        "action" => "run",
        "kind" => "execute",
        "user_id" => "usr_a"
      })

    page_result =
      row(5, "page_result", @system, ~s({"v":1,"ok":true,"result":"from-the-page"}), %{
        "tool_call_id" => "pcl_page",
        "name" => "execution.run",
        "status" => 200,
        "is_error" => false,
        "step_id" => "s_page"
      })

    rows = [
      row(1, "text", "usr_a", "@aqua read a.txt"),
      model_call,
      row(3, "tool_result", @system, "line 1", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "step_id" => "s1"
      }),
      page_call,
      page_result,
      row(6, "text", @agent, "Done.", %{"step_id" => "s2"}),
      row(7, "text", "usr_a", "and now?")
    ]

    without = rows -- [page_call, page_result]

    # The ordinary request, from the projection as the loop prunes it.
    ordinary = Request.messages(Planner.prune(rows), %{})
    assert ordinary == Request.messages(Planner.prune(without), %{})

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [%{"id" => "call_1"}]},
             %{"role" => "tool", "content" => [%{"tool_call_id" => "call_1"}]},
             %{"role" => "assistant"},
             %{"role" => "user"}
           ] = ordinary

    # The compaction's request, of the rows before a boundary that keeps
    # only the newest, as the loop summarizes them.
    %{first_kept_seq: kept} = Planner.boundary(rows, 1)
    assert kept > page_result.seq
    older = Enum.filter(rows, &(&1.seq < kept))
    summary = Planner.summary_request(Request.messages(older, %{}), model: "m")

    assert summary ==
             Planner.summary_request(Request.messages(older -- [page_call, page_result], %{}),
               model: "m"
             )

    for request <- [ordinary, summary] do
      sent = Jason.encode!(request)
      assert sent =~ "call_1"
      refute sent =~ "pcl_page"
      refute sent =~ "from-the-page"
    end
  end

  describe "a schedule's fire" do
    @line "[The schedule \"Morning\" (sched_1) fired with its line]\nsummarise what is unread"

    defp fire_row(seq) do
      struct(
        row(seq, "text", @system, "summarise what is unread", %{
          "schedule" => %{"id" => "sched_1", "name" => "Morning"}
        }),
        sent_by: "person",
        addressee: "aqua"
      )
    end

    test "reads to the model as the schedule's line, naming it by name and id" do
      # Only the server's voice names a schedule: a person's line carrying
      # the same payload reads as theirs, and a server's line with none as
      # the server's own.
      theirs =
        struct(
          row(2, "text", "usr_a", "and this", %{
            "schedule" => %{"id" => "sched_1", "name" => "x"}
          }),
          sent_by: "person"
        )

      unnamed = struct(row(3, "text", @system, "a plain line"), sent_by: "person")

      assert Request.messages([fire_row(1), theirs, unnamed], %{},
               me: "aqua",
               multi_author?: true,
               names: %{"usr_a" => "Ann"}
             ) == [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => @line},
                   %{"type" => "text", "text" => "Ann: and this"},
                   %{
                     "type" => "text",
                     "text" => "[A line from the server, not the person]\na plain line"
                   }
                 ]
               }
             ]
    end

    # The thread's summary asks for the rows it folds with no reader named
    # (`Aqua.Loop`'s compaction): the fire's line is still the schedule's,
    # never the agent's own words.
    test "reads as the schedule's line in a request that names no reader" do
      assert Request.messages([fire_row(1)], %{}) == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => @line}]}
             ]
    end
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

    messages = Request.messages(rows, %{})

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

  test "a post between a call and its result leaves the call answered by its own result, " <>
         "and a later round's reused id answers no earlier call" do
    call = fn seq, step ->
      row(seq, "tool_call", @agent, "files", %{
        "tool_call_id" => "call_1",
        "name" => "files",
        "arguments" => %{},
        "step_id" => step
      })
    end

    result = fn seq, content ->
      row(seq, "tool_result", @system, content, %{"tool_call_id" => "call_1", "name" => "files"})
    end

    # A post landed while the call waited; its result came after it. Rows
    # keep their places.
    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "user", "content" => [%{"text" => "never mind"}]},
             %{
               "role" => "tool",
               "content" => [%{"tool_call_id" => "call_1", "content" => "skipped"}]
             }
           ] =
             Request.messages(
               [
                 row(1, "text", "usr_a", "go"),
                 call.(2, "s1"),
                 row(3, "text", "usr_a", "never mind"),
                 result.(4, "skipped")
               ],
               %{}
             )

    # The first call has no result; the next round's call reuses its id and
    # is answered. The first is answered as unknown, right after it.
    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => [synthetic]},
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"role" => "tool", "content" => [%{"content" => "ok"}]}
           ] =
             Request.messages(
               [
                 row(1, "text", "usr_a", "go"),
                 call.(2, "s1"),
                 row(3, "turn_aborted", @system, "restart"),
                 call.(4, "s2"),
                 result.(5, "ok")
               ],
               %{}
             )

    assert synthetic["tool_call_id"] == "call_1" and synthetic["content"] =~ "outcome is unknown"
  end

  describe "crew rows" do
    defp crew(seq, sent_by, content, fields) do
      struct(row(seq, "text", if(sent_by == "person", do: "usr_a", else: @agent), content), [
        {:sent_by, sent_by} | fields
      ])
    end

    test "the reading agent's own speech is its own; a request, a reply and another agent's words are said to it" do
      rows = [
        crew(1, "person", "what next?", addressee: "aqua"),
        crew(2, "aqua", "Asking the planner.", payload: Jason.encode!(%{"step_id" => "s1"})),
        crew(3, "aqua", "plan it", addressee: "planner", status: "pending"),
        crew(4, "person", "check the logs", addressee: "builder", status: "answered"),
        crew(5, "builder", "Logs are clean.",
          addressee: "person",
          reply_to: "msg_4",
          outcome: "done"
        )
      ]

      assert [
               %{"role" => "user", "content" => [%{"text" => "what next?"}]},
               %{"role" => "assistant", "content" => [%{"text" => "Asking the planner."}]},
               %{"role" => "user", "content" => said}
             ] = Request.messages(rows, %{}, me: "aqua")

      texts = Enum.map(said, & &1["text"])

      # The soul's own request is its tool call's to show, not a row's.
      refute Enum.any?(texts, &(&1 =~ "plan it"))
      assert Enum.any?(texts, &(&1 =~ "usr_a asked builder (request msg_4, answered)"))
      assert Enum.any?(texts, &(&1 =~ "builder replied to request msg_4: done]\nLogs are clean."))

      # In the member's thread the soul's task is said to the member.
      assert [%{"role" => "user", "content" => [%{"text" => "[aqua]\nplan it"}]}] =
               Request.messages([crew(1, "aqua", "plan it", addressee: "planner")], %{},
                 me: "planner"
               )
    end

    # The thread's projection rides every request whole, and its last
    # message is the current ask. The shared vectors' case is this thread,
    # so the rule reads what the loop sends.
    test "a crew member's thread rides every request whole, its last message the current ask" do
      call = fn seq, step, id, name, arguments ->
        row(seq, "tool_call", @agent, name, %{
          "tool_call_id" => id,
          "name" => name,
          "arguments" => arguments,
          "step_id" => step
        })
      end

      result = fn seq, id, name, content, error? ->
        row(seq, "tool_result", @system, content, %{
          "tool_call_id" => id,
          "name" => name,
          "is_error" => error?
        })
      end

      rows = [
        row(1, "text", "usr_a", "an early word"),
        row(2, "compaction", @system, "The person wants the todo list kept short.", %{
          "first_kept_seq" => 3
        }),
        crew(3, "aqua", "Tidy notes/todo.md.", addressee: "claude-code", status: "answered"),
        crew(4, "claude-code", "I will read it first.",
          payload: Jason.encode!(%{"step_id" => "s1"})
        ),
        call.(5, "s1", "call_1", "files", %{"action" => "read", "path" => "notes/todo.md"}),
        result.(6, "call_1", "files", "1: buy milk\n2: call Ana", false),
        call.(7, "s2", "call_2", "files", %{"action" => "write", "path" => "notes/todo.md"}),
        call.(8, "s2", "call_3", "http", %{"action" => "get", "url" => "https://example.com"}),
        result.(9, "call_2", "files", "written", false),
        result.(10, "call_3", "http", "Refused by the person.", true),
        crew(11, "claude-code", "Done: two items are left.",
          payload: Jason.encode!(%{"step_id" => "s3"})
        ),
        crew(12, "aqua", "And add the dentist.", addressee: "claude-code", status: "pending")
      ]

      messages = Request.messages(rows, %{}, me: "claude-code")

      %{"cases" => [_alone, thread | _]} =
        "../../../../../tests/fixtures/session_context.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      assert messages == thread["messages"]

      assert %{"role" => "user", "content" => [%{"text" => "[aqua asked claude-code" <> _}]} =
               List.last(messages)

      assert Request.build(model: "m", messages: messages)["messages"] == messages
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

      [%{"role" => "user", "content" => blocks}] = Request.messages(rows, %{}, me: "aqua")
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
           ] = Request.messages(rows, %{}, excerpt: "Bob: hi")

    # Attachments ride on the initiating message, first user message.
    [%{"content" => content}] =
      Request.messages([row(1, "text", "usr_a", "see")], %{},
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
             Request.messages(rows, %{}, attachments: [image])

    assert [%{"content" => [_]}, _, %{"content" => [_, ^image]}] =
             Request.messages(rows, %{}, attachments: [image], task_message_id: "msg_3")
  end

  test "a later post's files ride its own message where it stands, before any merge" do
    first = %{"type" => "image", "media_type" => "image/png", "data" => "Zmlyc3Q="}
    later = %{"type" => "image", "media_type" => "image/png", "data" => "bGF0ZXI="}
    alone = %{"type" => "text", "text" => "The attached file notes.txt:\n\nstars"}
    call = %{"step_id" => "s1", "tool_call_id" => "c1", "name" => "notes", "arguments" => %{}}

    rows = [
      row(1, "text", "usr_a", "look"),
      row(2, "tool_call", @agent, nil, call),
      row(3, "text", "usr_a", "like this"),
      row(4, "text", "usr_a", ""),
      row(5, "tool_result", @agent, "kept", %{"tool_call_id" => "c1", "name" => "notes"}),
      row(6, "text", "usr_a", "and this, uncarried")
    ]

    assert Request.messages(rows, %{},
             attachments: [first],
             task_message_id: "msg_1",
             files: %{"msg_3" => [later], "msg_4" => [alone], "msg_9" => [later]}
           ) == [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "look"}, first]},
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "tool_call", "id" => "c1", "name" => "notes", "arguments" => %{}}
               ]
             },
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "like this"},
                 later,
                 %{"type" => "text", "text" => ""},
                 alone
               ]
             },
             %{
               "role" => "tool",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_call_id" => "c1",
                   "name" => "notes",
                   "content" => "kept",
                   "is_error" => false
                 }
               ]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "and this, uncarried"}]
             }
           ]
  end

  test "the provider's own search runs only when the member is offered it and the grant carries it" do
    granted = fn tools ->
      %Prima.Authority{resources: %Prima.Authority.Blob.Edge{tools: tools}}
    end

    on = %{"native_search" => "offered", "files.read" => "offered"}

    assert Request.native_search?(on, granted.(["files.read", "native_search"]))

    # The member is offered it, but the grant the turn runs under lacks it.
    refute Request.native_search?(on, granted.(["files.read"]))
    refute Request.native_search?(on, %Prima.Authority{resources: :none})

    # The grant carries it, but the member is not offered it.
    refute Request.native_search?(%{"files.read" => "offered"}, granted.(["native_search"]))
    refute Request.native_search?(%{}, granted.(["native_search"]))

    # A request offers it, and a turn records the open web, only where the
    # turn may search and the model has the tool.
    searching = %{provider_tools: ["web_search"]}
    assert Request.offers_search?(on, granted.(["native_search"]), searching)
    refute Request.offers_search?(on, granted.([]), searching)
    refute Request.offers_search?(on, granted.(["native_search"]), %{provider_tools: []})
  end

  test "the request carries the ceiling and the provider tools the catalyst offers" do
    caps = %{max_output_tokens: 4_000, default_max_tokens: 8_000, provider_tools: ["web_search"]}

    request =
      Request.build(model: "m", messages: [], tools: [], capabilities: caps, offers_search?: true)

    assert request["max_tokens"] == 4_000
    assert request["provider_tools"] == ["web_search"]

    assert Request.build(model: "m", messages: [], capabilities: caps)["provider_tools"] == []

    assert Request.build(model: "m", messages: [])["max_tokens"] == 16_384
  end

  test "an option rides the request only when the brain declares it, of its kind" do
    effort = %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]}
    caps = %{options: [effort]}

    request =
      Request.build(
        model: "m",
        messages: [],
        capabilities: caps,
        options: %{"effort" => "high"}
      )

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

  describe "a workspace thread's rows" do
    test "an opening reads as the ask by who asked, then each post it refers to as it reads now, then its files" do
      opening = %{
        row(1, "opening", "usr_1", "write the moon report", %{
          "ask" => "write the moon report",
          "asked_by" => "usr_1",
          "from" => %{"thread" => "thr_daily", "message" => "msg_ask"},
          "refs" => ["msg_ref", "msg_gone"],
          "title" => "Moon report",
          "attachments" => [
            %{
              "filename" => "moon.png",
              "stored_name" => "0-moon.png",
              "media_type" => "image/png",
              "size" => 4
            }
          ]
        })
        | sent_by: "person",
          thread_id: "thr_work"
      }

      cited = %{
        row(9, "text", "usr_1", "the moon is full tonight")
        | id: "msg_ref",
          sent_by: "person"
      }

      [%{"role" => "user", "content" => [%{"text" => text}]}] =
        Request.messages([opening], %{},
          me: "aqua",
          names: %{"usr_1" => "Ada"},
          refs: %{"msg_ref" => cited}
        )

      assert text =~ ~s|[Ada asked, in this workspace thread "Moon report" (thr_work)]|
      assert text =~ "write the moon report"
      assert text =~ "[Post msg_ref of the daily thread, by Ada]\nthe moon is full tonight"
      refute text =~ "msg_gone"
      assert text =~ "[Files carried in: moon.png]"
    end

    test "a file the person deleted is said removed where its post is, and never named as carried" do
      moon = %{
        "filename" => "moon.png",
        "stored_name" => "0-moon.png",
        "media_type" => "image/png"
      }

      notes = %{"filename" => "notes.txt", "stored_name" => "1-notes.txt"}

      opening = %{
        row(1, "opening", "usr_1", "write the moon report", %{
          "title" => "Moon report",
          "asked_by" => "usr_1",
          "attachments" => [moon, notes]
        })
        | sent_by: "person",
          thread_id: "thr_work"
      }

      older = %{
        row(2, "text", "usr_1", "and these", %{"attachments" => [moon, notes]})
        | sent_by: "person"
      }

      kept = %{
        row(3, "text", "usr_1", "and this one", %{"attachments" => [notes]})
        | sent_by: "person"
      }

      [%{"content" => blocks}] =
        Request.messages([opening, older, kept], %{"msg_1" => [moon], "msg_2" => [moon, notes]},
          me: "aqua",
          names: %{"usr_1" => "Ada"}
        )

      texts = Enum.map(blocks, & &1["text"])

      assert Enum.any?(texts, &(&1 =~ "[Files carried in: notes.txt]"))
      refute Enum.any?(texts, &(&1 =~ "Files carried in: moon.png"))

      assert Enum.filter(texts, &(&1 =~ "can no longer be read")) == [
               "[The person deleted these files of posts in this thread; they can no longer " <>
                 "be read: moon.png, moon.png, notes.txt]"
             ]
    end

    # Astra's probes (#4046): a row that draws nothing of its own, and one a
    # compaction pins, each still name the file that was deleted.
    test "a deleted file is named for a crew request a compaction pins" do
      ref = %{"filename" => "gone.png", "stored_name" => "0-gone.png"}

      request = %{
        row(1, "text", @agent, "read this", %{"attachments" => [ref]})
        | sent_by: "aqua",
          addressee: "planner",
          status: "pending"
      }

      compaction = row(2, "compaction", @system, "Earlier work", %{"first_kept_seq" => 3})
      ask = %{row(3, "text", "usr_1", "continue") | sent_by: "person"}

      text =
        [request, compaction, ask]
        |> Request.messages(%{"msg_1" => [ref]}, me: "aqua")
        |> Jason.encode!()

      assert text =~ "still waiting on its reply"
      assert text =~ "they can no longer be read: gone.png"
    end

    test "a deleted file of the reader's own post, which draws nothing of its own, is named" do
      ref = %{"filename" => "gone.png", "stored_name" => "0-gone.png"}

      post = %{
        row(1, "text", @agent, "Here it is", %{"post" => true, "attachments" => [ref]})
        | sent_by: "aqua"
      }

      ask = %{row(2, "text", "usr_1", "use that picture") | sent_by: "person"}

      text =
        [post, ask]
        |> Request.messages(%{"msg_1" => [ref]}, me: "aqua")
        |> Jason.encode!()

      refute text =~ "Here it is"
      assert text =~ "they can no longer be read: gone.png"
    end

    test "the rows a request carries are those its compaction keeps and pins" do
      pinned = %{
        row(1, "text", @agent, "read this")
        | sent_by: "aqua",
          addressee: "planner",
          status: "pending"
      }

      older = %{row(2, "text", "usr_1", "old") | sent_by: "person"}
      compaction = row(3, "compaction", @system, "Earlier", %{"first_kept_seq" => 4})
      kept = %{row(4, "text", "usr_1", "new") | sent_by: "person"}

      assert Enum.map(Request.carried([pinned, older, compaction, kept]), & &1.id) ==
               ["msg_1", "msg_4"]

      assert Enum.map(Request.carried([older, kept]), & &1.id) == ["msg_2", "msg_4"]
    end

    test "a pointer is one line naming its workspace thread; a report names it, its outcome and summary" do
      pointer = %{
        row(1, "pointer", @agent, "Moon report", %{
          "workspace" => "thr_work",
          "title" => "Moon report"
        })
        | sent_by: "aqua",
          workspace_id: "thr_work"
      }

      report = %{
        row(2, "report", @agent, "The report is written.", %{
          "workspace" => "thr_work",
          "title" => "Moon report",
          "outcome" => "done"
        })
        | sent_by: "aqua",
          workspace_id: "thr_work"
      }

      # Each is another thread's word to the reader, never its own speech.
      [%{"role" => "user", "content" => [%{"text" => pointed}, %{"text" => reported}]}] =
        Request.messages([pointer, report], %{}, me: "aqua")

      assert pointed ==
               ~s|[The workspace thread "Moon report" (thr_work) was opened or asked again from here]|

      assert reported ==
               ~s|[Report from the workspace thread "Moon report" (thr_work): done]\nThe report is written.|
    end

    test "a report names its outcome as the reader is told it: done, needing the person, " <>
           "or Aqua's error" do
      report = fn seq, payload ->
        %{
          row(seq, "report", @agent, "Summary #{seq}.", Map.put(payload, "title", "Moon report"))
          | sent_by: "aqua",
            workspace_id: "thr_work"
        }
      end

      rows = [
        report.(1, %{"outcome" => "done"}),
        report.(2, %{"outcome" => "needs_you"}),
        report.(3, %{"outcome" => "error"})
      ]

      [%{"role" => "user", "content" => content}] = Request.messages(rows, %{}, me: "aqua")

      assert Enum.map(content, & &1["text"]) == [
               ~s|[Report from the workspace thread "Moon report" (thr_work): done]\nSummary 1.|,
               ~s|[Report from the workspace thread "Moon report" (thr_work): needs the person]\nSummary 2.|,
               ~s|[Report from the workspace thread "Moon report" (thr_work): error, Aqua could not run it]\nSummary 3.|
             ]
    end

    test "the reader's own post is its call's to show; another agent's post reads under its name" do
      mine = %{row(1, "text", @agent, "the chart", %{"post" => true}) | sent_by: "aqua"}
      theirs = %{row(2, "text", @agent, "their chart", %{"post" => true}) | sent_by: "planner"}

      assert [%{"role" => "user", "content" => [%{"text" => "[planner]\ntheir chart"}]}] =
               Request.messages([mine, theirs], %{}, me: "aqua")
    end
  end
end
