# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLiveTest do
  @moduledoc """
  The chat list in the topbar: You and your groups, hidden as a list when
  there is only one, with "New group…" always there — the one create the
  home screen offers. Badges come from the athanors' notify topics.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.Athanors

  # The topbar is a nested LiveView; find it inside the page.
  defp topbar(view), do: find_live_child(view, "topbar")

  test "one athanor: no list, but New group… — which creates and opens the group", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {view, html} = mount_athanor(conn, "")

    bar = topbar(view)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    popover = render(bar)
    assert popover =~ "New group…"
    # a single athanor is not a list
    refute popover =~ "ath-"
    assert html =~ "CYFR"

    bar
    |> form("form[phx-submit=create_group]", %{"name" => "Garden #{alice.namespace}"})
    |> render_submit()

    [group] = Enum.filter(Athanors.list_for_user(alice.user_id), &(&1.name =~ "Garden"))
    assert_redirect(bar, PrismWeb.Focus.path(group, ""))
  end

  test "two athanors: a list with You and the group, badged by notifies for the one not in focus",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Bells #{alice.namespace}")

    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    assert render(bar) =~ "Bells"

    # something happens in the group while Home is in focus: a badge
    Sanctum.Notify.broadcast(group.id, :approval_pending, %{conversation_id: "c"})
    :sys.get_state(bar.pid)
    assert render(bar) =~ "bg-blue-500/80"

    # a card settled by someone, or a rename, does not add to the count
    before = render(bar)
    Sanctum.Notify.broadcast(group.id, :approval_resolved, %{})
    Sanctum.Notify.broadcast(group.id, :athanor_changed, %{name: "Bells"})
    :sys.get_state(bar.pid)
    assert render(bar) == before
  end
end
