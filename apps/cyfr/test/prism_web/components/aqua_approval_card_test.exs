# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaApprovalCardTest do
  # The card offers only the standing answers the action's own declaration
  # would accept — the same rule the runner and the grant store enforce —
  # so a visible button is never a button that can only fail: once, for
  # this run, for this thread until a time, always, for this schedule only
  # where the card's run has one, and a limit to the paths the call names
  # only for an action that declares which argument names one.
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

  test "for this schedule is offered only where the card's run was started by one" do
    assert %{schedule: false} = offers(card(%{"action_kind" => "write"}, scheduled: false))
    assert %{schedule: true} = offers(card(%{"action_kind" => "write"}, scheduled: true))

    # An action that stands in one thread only takes no agent-scope answer.
    assert %{schedule: false, always: false, run: true} =
             offers(card(%{"action_kind" => "write", "standing" => "thread"}, scheduled: true))
  end

  test "an action declared standing: false offers no standing answer" do
    assert %{once: true, run: false, until: false, always: false, schedule: false} =
             offers(card(%{"action_kind" => "write", "standing" => false}, scheduled: true))
  end

  test "an action declared standing: thread offers this thread's answers only" do
    assert %{run: true, until: true, always: false} =
             offers(card(%{"action_kind" => "write", "standing" => "thread"}))
  end

  test "a destructive or external action offers no standing answer, whatever it declares" do
    for kind <- ["destructive", "external"] do
      assert %{once: true, run: false, until: false, always: false, schedule: false} =
               offers(card(%{"action_kind" => kind}, scheduled: true))
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
  test "a canvas write's card names the streams the version reads" do
    streams_of = fn html ->
      case Regex.run(~r/data-test="approval-canvas-streams"[^>]*>(.*?)<\/div>/s, html,
             capture: :all_but_first
           ) do
        [named] -> named
        nil -> nil
      end
    end

    write = fn streams ->
      card(%{
        "action_kind" => "write",
        "proposal" => %{
          "tool" => "canvas",
          "action" => "write",
          "args" => %{
            "name" => "markets",
            "template" => "vanilla",
            "files" => %{"index.html" => "<html></html>"},
            "streams" => streams
          }
        }
      })
    end

    named =
      streams_of.(
        write.([
          %{"name" => "runs.changes"},
          %{"name" => "feed.results", "subject" => "btc"}
        ])
      )

    assert named =~ "this page will read:"
    assert named =~ "runs.changes, feed.results (btc)"
    assert streams_of.(write.([])) =~ "this page reads no stream"
    assert streams_of.(card(%{"action_kind" => "write"})) == nil
  end

  # canvas.write declares `standing: false`: with the standing its
  # declaration mints onto the card, the card offers this call's approval
  # and nothing that stands, so every write asks.
  test "a canvas write's card offers no standing answer, always included" do
    standing = Sanctum.Annotations.standing_to_wire(Aqua.Kinds.standing_for("canvas", "write"))
    assert standing == false

    html =
      card(
        %{
          "action_kind" => "write",
          "standing" => standing,
          "proposal" => %{
            "tool" => "canvas",
            "action" => "write",
            "args" => %{
              "name" => "markets",
              "template" => "vanilla",
              "files" => %{"index.html" => "<html></html>"},
              "streams" => []
            }
          }
        },
        scheduled: true
      )

    assert %{once: true, run: false, until: false, always: false, schedule: false} = offers(html)
    refute html =~ ~s(phx-value-scope="always")
  end
end
