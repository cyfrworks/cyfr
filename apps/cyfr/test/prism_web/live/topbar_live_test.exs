# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLiveTest do
  @moduledoc """
  The chat list in the topbar: You and your groups, hidden as a list when
  there is only one, with "New group…" always there — the one create the
  home screen offers. Badges come from the athanors' notify topics.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Sanctum.Tenancy.Athanors

  # The topbar is a nested LiveView; find it inside the page.
  defp topbar(view), do: find_live_child(view, "topbar")

  # The indicators the bar has been told to reload but has not reloaded yet.
  defp pending(bar), do: :sys.get_state(bar.pid).socket.assigns.refresh_pending

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
    assert_redirect(bar, PrismWeb.ChatLive.chat_path(Athanors.route_slug(group)))
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

    # A row opens the estate's chat; the small link beside it, its AQUA.
    route = Athanors.route_slug(group)
    assert has_element?(bar, ~s(a[href="#{PrismWeb.ChatLive.chat_path(route)}"]), "Bells")
    assert has_element?(bar, ~s(a[href="/a/#{route}/aqua"]), "AQUA")

    # something happens in a FOLLOWED thread of the group while another
    # estate is in focus: a badge. The creator follows their own thread.
    group_ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, thread} =
      Arca.ThreadStorage.create(Sanctum.Context.actor(group_ctx), %{title: "Bells thread"})

    Sanctum.Notify.broadcast(group.id, :approval_pending, %{thread_id: thread.id})
    :sys.get_state(bar.pid)
    assert render(bar) =~ "bg-blue-500/80"

    # a card settled by someone, or a rename, does not add to the count —
    # and neither does a thread this person does not follow: the tray is
    # where following becomes a notification fact.
    before = render(bar)
    Sanctum.Notify.broadcast(group.id, :approval_resolved, %{})
    Sanctum.Notify.broadcast(group.id, :athanor_changed, %{name: "Bells"})
    Sanctum.Notify.broadcast(group.id, :approval_pending, %{thread_id: "thread_unfollowed"})
    :sys.get_state(bar.pid)
    assert render(bar) == before
  end

  test "the bar follows the page only into an estate the person holds a seat in", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Seen #{alice.namespace}")
    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)
    viewing = fn -> :sys.get_state(bar.pid).socket.assigns.viewing end
    assert viewing.() == seated_athanor().id

    send(bar.pid, Cyfr.Bus.Viewing.new(group.id))
    assert viewing.() == group.id

    # An id that names no seat of theirs is not followed.
    send(bar.pid, Cyfr.Bus.Viewing.new("ath_nobody"))
    assert viewing.() == group.id
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
    {:ok, :created, _} = Sanctum.Door.Store.request("email", email, ops.user_id)
    Sanctum.Notify.allowlist_request(email)
    :sys.get_state(bar.pid)
    assert render(bar) =~ "1 request"

    [%{id: id}] = Sanctum.Door.Store.requests()

    ctx =
      Sanctum.Context.build(
        user_id: ops.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: true
      )

    assert {:ok, _} =
             Grimoire.Catalog.call_external("door", ctx, %{
               "action" => "resolve",
               "id" => id,
               "decision" => "reject"
             })

    :sys.get_state(bar.pid)
    refute has_element?(bar, "#door-requests")
  end

  test "a burst of telemetry costs one round of reads, not one per event", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "")
    bar = topbar(view)

    # Coalesce bursts of telemetry into one reload.
    actor = Prima.Actor.in_athanor(seated_athanor().id)
    for _ <- 1..10, do: send(bar.pid, Cyfr.Bus.Request.new(actor, :logged))
    :sys.get_state(bar.pid)

    # All ten have been seen and none has been served — that is the whole
    # claim. The two indicators a request invalidates are marked once.
    assert pending(bar) == MapSet.new([:requests, :log_stats])

    # One timer drains the set, and only `:do_refresh` empties it.
    wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the coalesced refresh to drain")

    # And the window re-arms: a burst after a drain is coalesced too, rather
    # than the bar going unthrottled or silent for the rest of the session.
    for _ <- 1..5, do: send(bar.pid, Cyfr.Bus.Execution.new(actor, :started))
    :sys.get_state(bar.pid)
    assert pending(bar) == MapSet.new([:executions])

    wait_until(fn -> Enum.empty?(pending(bar)) end, 2_000, "the second burst to drain")
  end
end
