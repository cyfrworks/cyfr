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

  test "the tray is the session's: a badge survives navigating, and opening the athanor clears it",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Tray #{alice.namespace}")

    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    Sanctum.Notify.broadcast(group.id, :execution_failed, %{})
    Sanctum.Notify.broadcast(group.id, :schedule_failed, %{})
    :sys.get_state(bar.pid)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    assert render(bar) =~ ~r/bg-blue-500\/80[^>]*>\s*2\s*</

    # Another page — the topbar remounts — and the count is still there.
    {view, _html} = mount_athanor(conn, "/settings")
    bar = topbar(view)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    assert render(bar) =~ ~r/bg-blue-500\/80[^>]*>\s*2\s*</

    # Opening the group reads it.
    {view, _html} = mount_athanor(conn, "", group)
    bar = topbar(view)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    refute render(bar) =~ "bg-blue-500/80"

    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    refute render(bar) =~ "bg-blue-500/80"
  end

  test "an operator sees how many wait at the door; the chip follows the door", %{conn: conn} do
    ops = test_user()
    conn = log_in_user(conn, ops)
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)

    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    refute has_element?(bar, "#door-requests")

    email = "carol-#{ops.namespace}@example.com"
    {:ok, _} = Sanctum.Door.Store.request(email, ops.user_id)
    Sanctum.Notify.allowlist_request(email)
    :sys.get_state(bar.pid)
    assert render(bar) =~ "1 request"

    [%{id: id}] = Sanctum.Door.Store.requests()

    ctx =
      Sanctum.Context.build(
        user_id: ops.user_id,
        athanor_id: Sanctum.Tenancy.Athanors.home!().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: true
      )

    assert {:ok, _} =
             Emissary.MCP.ToolRegistry.call_external("door", ctx, %{
               "action" => "resolve",
               "id" => id,
               "decision" => "reject"
             })

    :sys.get_state(bar.pid)
    refute has_element?(bar, "#door-requests")
  end
end
