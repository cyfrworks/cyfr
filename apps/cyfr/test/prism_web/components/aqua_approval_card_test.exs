# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaApprovalCardTest do
  # The card offers only the standing answers the action's own declaration
  # would accept — the same rule the runner and the grant store enforce —
  # so a visible button is never a button that can only fail: once, for
  # this run, for this thread until a time, always, for a schedule only
  # with one of the person's schedules to name, and a limit to the paths
  # the call names only for an action that declares which argument names
  # one.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp card(intent, assigns \\ []) do
    render_component(
      PrismWeb.AquaApprovalCard,
      Keyword.merge(
        [
          id: "card-1",
          message_id: "msg_1",
          approval_id: "apr_1",
          status: "pending",
          payload:
            Map.merge(
              %{
                "kind" => "request_approval",
                "title" => "Do the thing",
                "proposal" => %{"tool" => "notes", "action" => "keep", "args" => %{}}
              },
              intent
            )
        ],
        assigns
      )
    )
  end

  defp offers(html) do
    %{
      once: html =~ ~s(phx-value-scope="once"),
      run: html =~ ~s(phx-value-lifecycle="execution"),
      until: html =~ ~s(phx-value-hours=),
      always: html =~ ~r/phx-value-scope="always"(?![^>]*phx-value-lifecycle)/,
      schedule: html =~ ~s(phx-value-lifecycle="schedule"),
      limit: html =~ ~s(data-test="approval-limit")
    }
  end

  test "a write with no standing rule offers once, this run, this thread until a time, and always" do
    assert %{once: true, run: true, until: true, always: true, schedule: false, limit: false} =
             offers(card(%{"action_kind" => "write"}))

    html = card(%{"action_kind" => "write"})

    for {hours, text} <- [{"1", "1 hour"}, {"8", "8 hours"}, {"24", "24 hours"}] do
      assert html =~ ~s(phx-value-hours="#{hours}")
      assert html =~ text
    end
  end

  test "an action declared standing: false offers no standing answer" do
    assert %{once: true, run: false, until: false, always: false, schedule: false} =
             offers(card(%{"action_kind" => "write", "standing" => false}))
  end

  test "an action declared standing: thread offers this thread's answers only" do
    assert %{run: true, until: true, always: false} =
             offers(card(%{"action_kind" => "write", "standing" => "thread"}))
  end

  test "a destructive or external action offers no standing answer, whatever it declares" do
    for kind <- ["destructive", "external"] do
      assert %{once: true, run: false, until: false, always: false, schedule: false} =
               offers(card(%{"action_kind" => kind}))
    end
  end

  test "a limit to these paths is offered for an action that declares its path, in the door's spelling" do
    html =
      card(%{
        "action_kind" => "write",
        "proposal" => %{
          "tool" => "files",
          "action" => "write",
          "args" => %{"path" => "data//notes/today.md", "content" => "x"}
        }
      })

    assert %{limit: true} = offers(html)

    [limit] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test="approval-limit"]))
      |> Enum.map(&LazyHTML.text/1)

    assert limit =~ "data/notes/today.md"
    refute limit =~ "data//notes"

    # A folder keeps its trailing slash, so it covers what is inside it.
    assert card(%{
             "action_kind" => "read",
             "proposal" => %{
               "tool" => "files",
               "action" => "search",
               "args" => %{"base_path" => "data/notes/", "query" => "x"}
             }
           }) =~ "data/notes/"

    # An action that names no resource takes no constraint, and neither
    # does a call that names an unsafe path.
    assert %{limit: false} = offers(card(%{"action_kind" => "write"}))

    assert %{limit: false} =
             offers(
               card(%{
                 "action_kind" => "write",
                 "proposal" => %{
                   "tool" => "files",
                   "action" => "write",
                   "args" => %{"path" => "/etc/passwd"}
                 }
               })
             )
  end

  @schedules [%{id: "sch_morning", name: "Morning brief"}, %{id: "sch_evening", name: "Evening"}]

  test "for a schedule is offered with a schedule to name, one choice for each, and never without one" do
    html = card(%{"action_kind" => "write"}, schedules: @schedules)
    assert %{schedule: true, always: true} = offers(html)

    choices =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test="approval-for-schedule"] button))

    assert Enum.map(choices, &String.trim(LazyHTML.text(&1))) == ["Morning brief", "Evening"]

    for {choice, id} <- Enum.zip(choices, ["sch_morning", "sch_evening"]) do
      assert LazyHTML.attribute(choice, "phx-value-scope") == ["always"]
      assert LazyHTML.attribute(choice, "phx-value-lifecycle") == ["schedule"]
      assert LazyHTML.attribute(choice, "phx-value-schedule") == [id]
    end

    assert %{schedule: false} = offers(card(%{"action_kind" => "write"}, schedules: []))
  end

  test "for a schedule follows the rule of an answer for one thread: offered where that is, refused where it is not" do
    assert %{schedule: true, always: false} =
             offers(
               card(%{"action_kind" => "write", "standing" => "thread"}, schedules: @schedules)
             )

    for intent <- [
          %{"action_kind" => "write", "standing" => false},
          %{"action_kind" => "destructive"},
          %{"action_kind" => "external"}
        ] do
      assert %{schedule: false} = offers(card(intent, schedules: @schedules)), inspect(intent)
    end
  end

  test "a launch's card never offers an answer for a schedule" do
    launch = %{
      "action_kind" => "execute",
      "standing" => false,
      "proposal" => %{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => "reagent:local.mailer:1.0.0", "input" => %{}}
      }
    }

    html = card(launch, schedules: @schedules)
    assert %{once: true, schedule: false} = offers(html)
    refute html =~ "Morning brief"
  end

  test "a decided answer for a schedule names the schedule, or says a schedule once it is gone" do
    decided = fn schedules ->
      card(%{"action_kind" => "write"},
        status: "approved",
        scope: :always,
        schedules: schedules,
        bounds: %{"lifecycle" => "schedule", "schedule" => "sch_evening"}
      )
    end

    html = decided.(@schedules)
    assert html =~ "for the runs of Evening, until it is deleted"
    refute html =~ "won't ask again"
    refute html =~ "ending with its schedule"

    assert decided.([]) =~ "for the runs of a schedule, until it is deleted"
  end

  test "a decided standing answer says what it ends with" do
    html =
      card(%{"action_kind" => "write"},
        status: "approved",
        scope: :thread,
        bounds: %{
          "lifecycle" => "execution",
          "constraint" => %{"kind" => "storage_path", "patterns" => ["data/notes/"]}
        }
      )

    assert html =~ "standing for this chat"
    assert html =~ "ending with its execution"
    assert html =~ "for data/notes/"
  end

  test "the card names what the turn read: each class, and every outside source by its name" do
    read = [
      %{"class" => "pinned", "name" => nil},
      %{"class" => "filed", "name" => nil},
      %{"class" => "outside", "name" => "news.example"},
      %{"class" => "outside", "name" => nil}
    ]

    html = card(%{"action_kind" => "write", "sources" => read})

    assert html =~ ~s(data-test="approval-sources")
    assert html =~ "the pinned page, filed notes, outside material"
    assert html =~ "an unnamed source, news.example"

    # A standing answer may follow only the named outside sources.
    assert html =~ ~s(data-test="approval-follows")
    assert html =~ ~s(phx-click="approval:toggle_follows")
    [follows] = Regex.run(~r/also when it follows:.*?<\/label>/s, html)
    assert follows =~ "news.example"
    refute follows =~ "unnamed"
  end

  test "a turn that read nothing, or nothing named from outside, offers no follows" do
    refute card(%{"action_kind" => "write"}) =~ ~s(data-test="approval-sources")

    html = card(%{"action_kind" => "write", "sources" => [%{"class" => "filed", "name" => nil}]})
    assert html =~ "after reading: filed notes"
    refute html =~ ~s(data-test="approval-follows")
  end

  test "a decided standing answer says which outside sources it also follows" do
    html =
      card(%{"action_kind" => "write"},
        status: "approved",
        scope: :thread,
        bounds: %{"sources" => [%{"class" => "outside", "name" => "news.example"}]}
      )

    assert html =~ "also after news.example"
  end

  # A canvas write's card names the streams the version reads, from the
  # proposal the approval binds, each feed by its name; another call's
  # card says nothing of streams.
  describe "a program's start" do
    defp program_card do
      card(%{
        "action_kind" => "execute",
        "program" => %{
          "row" => "mcp_gh",
          "name" => "gh",
          "command" => "gh --hostname github.com",
          "epoch" => 3,
          "folder" => "its own folder",
          "hosts" => "api.github.com"
        },
        "proposal" => %{
          "tool" => "program",
          "action" => "start",
          "args" => %{
            "program" => "mcp_gh",
            "epoch" => 3,
            "terminal_args" => ["repo", "view", "a b", "it's", "x\ey"]
          }
        }
      })
    end

    test "shows the program, its folder and hosts, its pinned command and every word, quoted, unfolded" do
      html = program_card()
      doc = LazyHTML.from_fragment(html)
      shown = LazyHTML.query(doc, ~s([data-test="approval-program"]))
      text = shown |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

      assert text =~ "runs gh"
      assert text =~ "in its own folder, reaching api.github.com"

      command = LazyHTML.query(doc, ~s([data-test="approval-program-command"]))

      assert LazyHTML.text(command) ==
               ~S(gh --hostname github.com "repo" "view" "a b" "it's" "x\u{1B}y")

      assert doc |> LazyHTML.query(~s([data-test="approval-program-word"])) |> Enum.count() == 5

      # Not inside the folded details: shown as the card opens.
      assert doc |> LazyHTML.query(~s(details [data-test="approval-program"])) |> Enum.count() ==
               0
    end

    test "draws every word whole, however long, quoted and escaped, with nothing cut" do
      # 32 words of 256 characters each, multi-byte, with quotes and
      # backslashes: the most a start's bounds let through.
      words =
        for i <- 1..32 do
          word = String.slice(String.duplicate(~s(é"\\#{i}), 100), 0, 256)
          assert String.length(word) == 256
          word
        end

      html =
        card(%{
          "action_kind" => "execute",
          "program" => %{
            "row" => "mcp_gh",
            "name" => "gh",
            "command" => "gh",
            "epoch" => 3,
            "folder" => "its own folder",
            "hosts" => "every public host"
          },
          "proposal" => %{
            "tool" => "program",
            "action" => "start",
            "args" => %{"program" => "mcp_gh", "epoch" => 3, "terminal_args" => words}
          }
        })

      shown =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test="approval-program-word"]))
        |> Enum.map(&LazyHTML.text/1)

      expected =
        for word <- words,
            do:
              ~s(") <>
                (word |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))) <>
                ~s(")

      assert shown == expected
    end

    test "a character a reader could not see is drawn as its code point" do
      for {char, spelled} <- [
            {<<0x202E::utf8>>, ~S(\u{202E})},
            {<<0x200B::utf8>>, ~S(\u{200B})},
            {<<0x2028::utf8>>, ~S(\u{2028})},
            {<<1>>, ~S(\u{1})}
          ] do
        html =
          card(%{
            "action_kind" => "execute",
            "program" => %{
              "row" => "mcp_gh",
              "name" => "gh",
              "command" => "gh",
              "epoch" => 3,
              "folder" => "its own folder",
              "hosts" => "every public host"
            },
            "proposal" => %{
              "tool" => "program",
              "action" => "start",
              "args" => %{
                "program" => "mcp_gh",
                "epoch" => 3,
                "terminal_args" => ["first" <> char <> "last"]
              }
            }
          })

        [word] =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s([data-test="approval-program-word"]))
          |> Enum.map(&LazyHTML.text/1)

        assert word == ~s("first) <> spelled <> ~s(last")
        refute String.contains?(word, char)
      end
    end

    test "one that does not carry what it runs is shown, never approved" do
      html =
        card(%{
          "action_kind" => "execute",
          "proposal" => %{
            "tool" => "program",
            "action" => "start",
            "args" => %{"program" => "mcp_gh", "epoch" => 3, "terminal_args" => []}
          }
        })

      assert html =~ "This card cannot show what the program would run, so it cannot be approved."
      assert %{once: false, run: false, until: false, always: false} = offers(html)
    end

    test "says what every start widens in plain words, and chooses nothing until pressed" do
      html = program_card()

      assert html =~ "also approve every start of gh, whatever follows its"
      assert html =~ "command, in its own folder, reaching api.github.com:"
      refute html =~ "also approve:"
      assert %{once: true, run: true, until: true, always: true, limit: false} = offers(html)
      refute html =~ ~r/<input[^>]*checked/
    end
  end

  test "a canvas write's card names the streams the version reads" do
    streams_of = fn html ->
      case Regex.run(~r/data-test="approval-canvas-streams"[^>]*>(.*?)<\/div>/s, html,
             capture: :all_but_first
           ) do
        [named] -> named
        nil -> nil
      end
    end

    write = fn desktop ->
      card(%{
        "action_kind" => "write",
        "proposal" => %{
          "tool" => "canvas",
          "action" => "write",
          "args" =>
            %{
              "name" => "markets",
              "template" => "vanilla",
              "files" => %{"index.html" => "<html></html>"}
            }
            |> Map.merge(desktop)
        }
      })
    end

    named =
      streams_of.(write.(%{"data" => ["runs.changes"], "feeds" => ["btc"]}))

    assert named =~ "this page will read:"
    assert named =~ "runs.changes, feed.results (btc)"
    assert streams_of.(write.(%{})) =~ "this page reads no stream"
    assert streams_of.(write.(%{"data" => [], "feeds" => []})) =~ "this page reads no stream"
    assert streams_of.(write.(%{"data" => "runs.changes"})) =~ "a stream entry the write refuses"
    assert streams_of.(write.(%{"feeds" => [7]})) =~ "a stream entry the write refuses"
    assert streams_of.(card(%{"action_kind" => "write"})) == nil
  end

  # canvas.write declares `standing: false`: with the standing its
  # declaration mints onto the card, the card offers this call's approval
  # and nothing that stands, so every write asks.
  test "a canvas write's card offers no standing answer, always included" do
    standing = Sanctum.Annotations.standing_to_wire(Aqua.Kinds.standing_for("canvas", "write"))
    assert standing == false

    html =
      card(%{
        "action_kind" => "write",
        "standing" => standing,
        "proposal" => %{
          "tool" => "canvas",
          "action" => "write",
          "args" => %{
            "name" => "markets",
            "template" => "vanilla",
            "files" => %{"index.html" => "<html></html>"}
          }
        }
      })

    assert %{once: true, run: false, until: false, always: false, schedule: false} = offers(html)
    refute html =~ ~s(phx-value-scope="always")
  end
end
