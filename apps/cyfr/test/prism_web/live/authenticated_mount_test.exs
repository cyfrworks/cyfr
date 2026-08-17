# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthenticatedMountTest do
  @moduledoc """
  The harness contract: a signed-in test user (claimed namespace, membership,
  session) mounts an authenticated LiveView; a session without a claimed
  namespace is sent to the claim gate.
  """

  use PrismWeb.ConnCase, async: false

  test "a signed-in user mounts /settings", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)

    {view, html} = mount_athanor(conn, "/settings")

    assert html =~ user.email
    assert render(view) =~ "Settings"
  end

  test "a mounted view lets go when the person's sessions are revoked", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/settings")

    {:ok, _} = Sanctum.Session.revoke_all_for_user(user.user_id)
    assert_redirect(view, "/login")
  end

  test "a mounted view lets go when the person loses the athanor in focus", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/settings")

    home = Sanctum.Tenancy.Athanors.home!()
    # Home is never archived by a leave; the person simply loses their seat.
    :ok = Sanctum.Tenancy.Members.remove_member(home, user_id: user.user_id)
    assert_redirect(view, "/")
  end

  test "an anonymous conn is redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, athanor_path("/settings"))
  end

  test "a session without a claimed namespace is sent to the claim gate", %{conn: conn} do
    conn = log_in_user(conn, test_user(), claim: false)

    assert {:error, {:redirect, %{to: to}}} = live(conn, athanor_path("/settings"))
    assert to =~ "/claim-namespace"
  end

  test "focus is the URL: a member mounts their group, a stranger is sent home, an unknown slug too",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Focus #{user.namespace}")

    {view, _html} = mount_athanor(conn, "/members", group)
    assert render(view) =~ group.name

    other = test_user()

    {:ok, stranger_group} =
      Sanctum.Tenancy.Athanors.create_group(other.user_id, "Not yours #{other.namespace}")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, athanor_path("/members", stranger_group))

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/a/no-such-group/members")

    # a person's own athanor is addressed as @<namespace>
    {:ok, personal} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: user.namespace,
        owner_user_id: user.user_id,
        created_by: user.user_id
      })

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: personal.id)

    {view, _html} = mount_athanor(conn, "/members", personal)
    assert render(view) =~ "Your own athanor"
  end

  test "the root lands in the session's athanor", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    home = Sanctum.Tenancy.Athanors.home!()
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
    assert to == PrismWeb.Focus.path(home, "")
  end

  test "lite mode hides the developer views and speaks the everyday words", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)

    # Dev (the default): the full sidebar in the runtime's vocabulary.
    {_view, html} = mount_athanor(conn, "/settings")
    assert html =~ "nav-executions"
    assert html =~ "Tinctures"

    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email
      })

    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "lite"})

    {_view, html} = mount_athanor(conn, "/settings")
    refute html =~ "nav-executions"
    refute html =~ "nav-api-keys"
    assert html =~ "nav-chat"
    assert html =~ "Apps"
    refute html =~ ">Tinctures<"
  end

  test "lite is chat + switcher + drawer: no sidebar, no live indicators; dev keeps both",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)

    # Dev: the sidebar with every page (webhooks and enforcements included),
    # the live indicators, and the drawer for narrow screens.
    {view, html} = mount_athanor(conn, "/settings")
    assert html =~ ~s(id="nav-webhooks")
    assert html =~ ~s(id="nav-enforcements")
    assert has_element?(view, "#drawer #drawer-nav-executions")
    assert render(find_live_child(view, "topbar")) =~ ~s(id="live-indicators")

    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email
      })

    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "lite"})

    # Lite: no sidebar link at all, the drawer holds the lite pages, and the
    # topbar carries no indicators — the drawer button is always shown.
    {view, html} = mount_athanor(conn, "/settings")
    refute html =~ ~s(id="nav-chat")
    refute html =~ ~s(id="nav-webhooks")

    for key <-
          ~w(chat agents tinctures members connections schedules webhooks mcp-servers settings) do
      assert has_element?(view, "#drawer #drawer-nav-#{key}"), "lite drawer lacks #{key}"
    end

    for key <- ~w(executions api-keys enforcements builds registry) do
      refute has_element?(view, "#drawer #drawer-nav-#{key}"), "lite drawer shows #{key}"
    end

    bar = find_live_child(view, "topbar")
    refute render(bar) =~ ~s(id="live-indicators")
    assert has_element?(bar, "#open-drawer")
    assert has_element?(bar, "#open-palette")
    assert has_element?(view, "#drawer-search")
    assert has_element?(view, "#drawer-new-group")
  end

  test "the chat page's thread list is a panel a phone can open and close", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {_view, html} = mount_athanor(conn, "")
    assert html =~ ~s(id="conversation-list")
    assert html =~ "max-md:hidden"
  end
end
