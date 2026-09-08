# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RedirectLiveTest do
  @moduledoc """
  The addresses that moved: an athanor's chat (`/a/<route>`) is the chat
  zone with the estate named, and its agents page (`/a/<route>/agents`) is
  its AQUA. Each forwards whatever query it was given.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    home = Athanors.home!()
    {:ok, conn: log_in_user(conn, test_user()), route: Athanors.route_slug(home)}
  end

  test "/a/<route> forwards to the chat with the estate named first and the query kept",
       %{conn: conn, route: route} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/a/#{route}")
    assert to == "/chat?a=#{route}"

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/a/#{route}?c=x&foo=1")
    assert to == "/chat?a=#{route}&c=x&foo=1"

    # The path names the estate; a stray `a` in the query does not.
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/a/#{route}?a=other&c=x")
    assert to == "/chat?a=#{route}&c=x"
  end

  test "/a/<route>/agents forwards to the estate's AQUA, query and all",
       %{conn: conn, route: route} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/a/#{route}/agents")
    assert to == "/a/#{route}/aqua"

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/a/#{route}/agents?x=1")
    assert to == "/a/#{route}/aqua?x=1"
  end
end
