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
end
