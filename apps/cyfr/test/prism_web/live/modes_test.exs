# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModesTest do
  @moduledoc """
  The two modes, Dashboard and Canvas, on the top bar: the switch shows the
  page's mode and leads to the other; the Canvas mode is the shell at
  `/a/<athanor>/canvas`, with no sidebar and no drawer, refused for an
  athanor the person is not in, and `/tinctures` is gone; the mode and the
  last Dashboard page are remembered per browser session, so `/` returns
  to the Canvas the person left, and a remembered value that is not a mode
  reads as the Dashboard.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    token = Plug.Conn.get_session(conn, :sanctum_session_token)
    {:ok, conn: conn, user: user, athanor: athanor, token: token}
  end

  defp topbar(view), do: find_live_child(view, "topbar")
  defp route(athanor), do: Athanors.route_slug(athanor)

  defp switch!(view, surface) do
    assert {:error, {:live_redirect, %{to: to}}} =
             view |> topbar() |> element("#mode-#{surface}") |> render_click()

    to
  end

  describe "the switch" do
    test "on a Dashboard page, Dashboard is current and Canvas leads to the shell", %{
      conn: conn,
      athanor: athanor
    } do
      {view, _html} = mount_athanor(conn, "/vault")
      bar = topbar(view)

      assert has_element?(bar, ~s(#mode-switch[phx-hook="ModeSwitch"]))
      assert has_element?(bar, ~s(#mode-dashboard[aria-current="page"]), "Dashboard")
      refute has_element?(bar, ~s(#mode-canvas[aria-current]))

      # The Dashboard keeps its sidebar or drawer, and its drawer button.
      assert has_element?(view, "#chrome-side #drawer")
      refute has_element?(bar, "#open-drawer[hidden]")

      assert switch!(view, "canvas") == "/a/#{route(athanor)}/canvas"
    end

    test "in the Canvas, Canvas is current, nothing beside it, and Dashboard leads back to the page left",
         %{conn: conn, athanor: athanor} do
      {view, _html} = mount_athanor(conn, "/vault")
      to = switch!(view, "canvas")
      {:ok, canvas, _html} = live(conn, to)
      bar = topbar(canvas)

      assert has_element?(bar, ~s(#mode-canvas[aria-current="page"]), "Canvas")
      refute has_element?(canvas, "#chrome-side")
      refute has_element?(canvas, "#drawer")
      assert has_element?(bar, "#open-drawer[hidden]")
      assert switch!(canvas, "dashboard") == "/a/#{route(athanor)}/vault"
    end

    test "with no Dashboard page in this session, Dashboard leads to the chat", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/canvas")
      assert switch!(view, "dashboard") =~ "/chat"
    end
  end

  describe "the routes" do
    test "the Canvas mode is the shell; /tinctures is gone", %{conn: conn, athanor: athanor} do
      {view, _html} = mount_athanor(conn, "/canvas")
      assert view.module == PrismWeb.ShellLive

      assert get(conn, "/a/#{route(athanor)}/tinctures").status == 404
    end

    test "the Canvas of an athanor the person is not in is refused, as any page of it is",
         %{conn: conn} do
      {:ok, other} =
        Athanors.create(%{
          kind: "group",
          name: "Elsewhere",
          slug: "elsewhere-#{System.unique_integer([:positive])}",
          created_by: "system"
        })

      {:ok, other} = Sanctum.TestContext.mark_provisioned(other)

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               refused = live(conn, "/a/#{route(other)}/canvas")

      assert refused == live(conn, "/a/#{route(other)}/vault")
    end

    test "the nav names no Tinctures page and no /tinctures path" do
      for mode <- ~w(lite dev), item <- PrismWeb.Nav.items(mode) do
        refute item.key == "tinctures", mode
        refute item.path =~ "tinctures", mode
      end
    end
  end

  describe "the mode remembered for the browser session" do
    test "/ returns to the Canvas the person left, and to the chat once they left the Dashboard",
         %{conn: conn, athanor: athanor, token: token} do
      {_view, _html} = mount_athanor(conn, "/canvas")
      assert %{surface: "canvas"} = PrismWeb.Surface.recall(token)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
      assert to == "/a/#{route(athanor)}/canvas"

      {_view, _html} = mount_athanor(conn, "/schedules")
      assert %{surface: "dashboard", page: "schedules"} = PrismWeb.Surface.recall(token)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
      assert to =~ "/chat"

      # Back in the Canvas, the Dashboard page is kept.
      {_view, _html} = mount_athanor(conn, "/canvas")
      assert %{surface: "canvas", page: "schedules"} = PrismWeb.Surface.recall(token)
    end

    test "a remembered value that is not a mode reads as the Dashboard", %{
      conn: conn,
      token: token
    } do
      Arca.Cache.put(
        {:surface, Prism.Tray.session_hash(token)},
        %{surface: "glass", page: 7},
        60_000
      )

      assert %{surface: "dashboard", page: nil} = PrismWeb.Surface.recall(token)
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
      assert to =~ "/chat"

      assert PrismWeb.Surface.read("canvas") == "canvas"
      assert PrismWeb.Surface.read(nil) == "dashboard"
      assert PrismWeb.Surface.read(:canvas) == "dashboard"
    end

    test "a session without a token remembers nothing" do
      assert :ok = PrismWeb.Surface.remember(nil, "canvas")
      assert %{surface: "dashboard", page: nil} = PrismWeb.Surface.recall(nil)
    end
  end
end
