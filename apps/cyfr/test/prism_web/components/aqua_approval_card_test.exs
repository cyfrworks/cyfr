# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaApprovalCardTest do
  # The card offers only the standing answers the action's own declaration
  # would accept — the same rule the runner and the grant store enforce —
  # so a visible button is never a button that can only fail.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp card(intent) do
    render_component(PrismWeb.AquaApprovalCard,
      id: "card-1",
      message_id: "apr_1",
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
    )
  end

  test "a write with no standing rule offers both standing answers" do
    html = card(%{"action_kind" => "write"})
    assert html =~ "for this chat"
    assert html =~ ~s(phx-value-scope="always")
  end

  test "an action declared standing: false offers neither" do
    html = card(%{"action_kind" => "write", "standing" => false})
    refute html =~ "for this chat"
    refute html =~ ~s(phx-value-scope="always")
    # The one-time approve is still there.
    assert html =~ ~s(phx-value-scope="once")
  end

  test "an action declared standing: conversation offers this chat only" do
    html = card(%{"action_kind" => "write", "standing" => "conversation"})
    assert html =~ "for this chat"
    refute html =~ ~s(phx-value-scope="always")
  end

  test "a destructive or external action offers neither, whatever it declares" do
    for kind <- ["destructive", "external"] do
      html = card(%{"action_kind" => kind})
      refute html =~ "for this chat"
      refute html =~ ~s(phx-value-scope="always")
    end
  end
end
