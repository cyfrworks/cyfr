# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.NavTest do
  use ExUnit.Case, async: true

  alias PrismWeb.Nav

  test "lite is the everyday pages, flat" do
    keys = Enum.map(Nav.items("lite"), & &1.key)

    assert keys ==
             ~w(aqua files vault schedules webhooks programs settings legal)

    refute "executions" in keys
    refute "api_keys" in keys
    assert [{nil, items}] = Nav.sections("lite")
    assert length(items) == length(keys)
  end

  test "dev is every page, sectioned, webhooks and enforcements included" do
    keys = Enum.map(Nav.items("dev"), & &1.key)

    for key <-
          ~w(files executions enforcements components builds registry api_keys webhooks reports) do
      assert key in keys, "dev lacks #{key}"
    end

    titles = Nav.sections("dev") |> Enum.map(&elem(&1, 0))
    assert titles == [nil, "Observability", "Components", "Configuration", "Other"]
  end

  test "a mode shows its pages, a record under one and the desktop, and nothing else" do
    assert Nav.shown?("/vault", "lite")
    assert Nav.shown?("/schedules/sched_abc?tab=runs", "lite")
    refute Nav.shown?("/executions", "lite")
    assert Nav.shown?("/executions/exec_abc", "dev")

    for mode <- ~w(lite dev) do
      assert Nav.shown?(Nav.desktop_path(), mode)
      assert Nav.shown?(Nav.desktop_path() <> "?publisher=acme&tincture_name=widget", mode)
      refute Nav.shown?("/tinctures", mode)
      refute Nav.shown?("/canvas", mode)
      refute Nav.shown?("/chat", mode)
    end
  end

  test "an unknown mode is the default, lite, and ids keep the sidebar's spelling" do
    assert Nav.items(nil) == Nav.items("lite")
    assert Nav.dom_id("nav", "api_keys") == "nav-api-keys"
    assert Nav.dom_id("drawer-nav", "programs") == "drawer-nav-programs"
  end

  test "every nav destination is a routed page" do
    # The sidebar, the drawer and the palette all derive from Nav; a nav
    # item whose path the router does not serve is a dead link on every
    # one of them. Dev mode is the full set.
    route_paths =
      Cyfr.Boundaries.routes()
      |> Enum.map(& &1.path)
      |> MapSet.new()

    for item <- Nav.items("dev") do
      expected = "/a/:athanor" <> item.path

      assert MapSet.member?(route_paths, expected),
             "nav item #{item.key} points at #{item.path}, but no route serves #{expected}"
    end
  end

  test "every link is focused on the athanor, a bare path and a query string alike" do
    aqua = Enum.find(Nav.items("lite"), &(&1.key == "aqua"))
    assert Nav.href(aqua, "home") == "/a/home/aqua"

    # A bare path decides the same way — the palette and an intent hand
    # one in — and a query string does not change the answer.
    assert Nav.href("/aqua", "home") == "/a/home/aqua"
    assert Nav.href("/executions?id=exec_1", "home") == "/a/home/executions?id=exec_1"
    assert Nav.href("/?publisher=p&tincture_name=n", "home") == "/a/home/?publisher=p&tincture_name=n"
    refute Enum.any?(Nav.items("dev"), &(&1.key == "chat"))
  end

  # The one place a navigate the assistant proposes meets the router: a
  # page the console serves passes, with its parameters; a redirect stub
  # and a path no route matches do not.
  test "a navigate lands on a page the router serves: every nav item, a record's page, no stub" do
    focus = "/a/:athanor"

    stubs =
      for %{path: path, metadata: %{phoenix_live_view: live}} <- Cyfr.Boundaries.routes(),
          is_tuple(live),
          live |> elem(0) |> Atom.to_string() |> String.ends_with?("RedirectLive"),
          do: String.replace(path, ":athanor", "home")

    assert "/chat" in stubs

    for stub <- stubs do
      refute Nav.page?(stub), "#{stub} forwards elsewhere and must not be a navigate target"
    end

    assert Nav.page?(focus |> String.replace(":athanor", "home"))

    for mode <- ~w(dev lite), item <- Nav.items(mode) do
      assert Nav.page?(Nav.href(item, "home")),
             "#{mode} nav offers #{item.path}, the router does not"
    end

    assert Nav.page?(Nav.href("/executions?id=exec_a", "home"))
    assert Nav.page?(Nav.href("/components/local.weather-app", "home"))
    refute Nav.page?(Nav.href("/etc/passwd", "home"))
    refute Nav.page?(Nav.href("/components/not/a/page", "home"))
  end
end
