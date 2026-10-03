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
end
