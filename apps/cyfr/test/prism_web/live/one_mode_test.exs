# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.OneModeTest do
  @moduledoc """
  One screen: sign-in lands on the desktop, every Dashboard page draws over
  it as an overlay, the desktop is rendered beside the page by the session's
  root layout rather than routed, the gear, the chat and AQUA stand at the
  shelf's right end, and no mode switch remains.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, athanor: seated_athanor()}
  end

  defp route(athanor), do: Athanors.route_slug(athanor)

  # The desktop's LiveView, as the session's root layout renders it beside
  # the page's: a root view of its own, its signed session on its container,
  # the shell inside it.
  defp desktop?(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("body > [data-phx-session]:not([data-phx-main]) > #shell")
    |> Enum.count() == 1
  end

  describe "the desktop" do
    test "sign-in lands on it: / is the desktop alone, the desktop beside it and no overlay",
         %{conn: conn, athanor: athanor} do
      for path <- ["/", "/a", "/a/#{route(athanor)}"] do
        {:ok, view, _html} = live(conn, path)
        assert view.module == PrismWeb.DesktopLive, path
        refute has_element?(view, "#settings-overlay"), path

        html = conn |> get(path) |> html_response(200)
        assert desktop?(html), path
      end
    end

    test "a Dashboard page draws over the desktop, with the page list and a close back to it",
         %{conn: conn, athanor: athanor} do
      {view, _html} = mount_athanor(conn, "/vault")
      assert has_element?(view, "#settings-overlay")
      assert has_element?(view, ~s(#settings-close[href="/a/#{route(athanor)}"]))
      assert has_element?(view, "#drawer")

      html = conn |> get("/a/#{route(athanor)}/vault") |> html_response(200)
      assert desktop?(html)
    end

    test "the top bar has no mode switch, and its drawer button stands on every page",
         %{conn: conn} do
      for path <- ["/vault", ""] do
        {view, _html} = mount_athanor(conn, path)
        bar = find_live_child(view, "topbar")
        refute has_element?(bar, "#mode-switch"), path
        refute has_element?(bar, "[data-mode]"), path
        assert has_element?(bar, "#open-drawer"), path
        refute has_element?(bar, "#open-drawer[hidden]"), path
      end
    end

    test "the Canvas's old address is gone and the chat's forwards to the desktop",
         %{conn: conn, athanor: athanor} do
      assert get(conn, "/a/#{route(athanor)}/canvas").status == 404
      assert get(conn, "/a/#{route(athanor)}/tinctures").status == 404

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/chat")
      assert to == "/a/#{route(athanor)}"

      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, "/chat?s=thread_x&c=y")
    end
  end

  describe "the shelf's right end" do
    test "holds the gear to the Settings page, the chat and AQUA, the desktop's own",
         %{conn: conn, athanor: athanor} do
      {view, html} = mount_desktop(conn)

      assert has_element?(
               view,
               ~s(#shelf-end #shelf-gear[href="/a/#{route(athanor)}/settings"][data-phx-link="redirect"])
             )

      assert find_live_child(view, "chat-overlay")
      assert find_live_child(view, "aqua-panel")
      assert html =~ ~s(phx-hook="ShellPage")
    end
  end

  describe "the nav" do
    test "names no chat, no Canvas and no Tinctures page; the desktop is shown in every UI mode" do
      for mode <- ~w(lite dev) do
        for item <- PrismWeb.Nav.items(mode) do
          refute item.key in ~w(chat canvas tinctures), mode
          refute item.path in ~w(/chat /canvas /tinctures), mode
        end

        assert PrismWeb.Nav.shown?("/?publisher=acme&tincture_name=widget", mode)
      end

      assert PrismWeb.Nav.href("/settings", "@alice") == "/a/@alice/settings"
      assert PrismWeb.Nav.page?("/a/@alice?publisher=acme&tincture_name=widget")
      refute PrismWeb.Nav.page?("/chat")
    end
  end
end
