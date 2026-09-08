# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.NavTest do
  use ExUnit.Case, async: true

  alias PrismWeb.Nav

  test "lite is chat and a drawer: the everyday pages, flat, apps first-named" do
    keys = Enum.map(Nav.items("lite"), & &1.key)

    assert keys ==
             ~w(chat aqua tinctures members vault schedules webhooks mcp_servers settings legal)

    refute "executions" in keys
    refute "api_keys" in keys
    assert [{nil, items}] = Nav.sections("lite")
    assert length(items) == length(keys)
    assert Enum.find(items, &(&1.key == "tinctures")).label == "Apps"
  end

  test "dev is every page, sectioned, webhooks and enforcements included" do
    keys = Enum.map(Nav.items("dev"), & &1.key)

    for key <-
          ~w(chat executions enforcements components builds registry api_keys webhooks reports) do
      assert key in keys, "dev lacks #{key}"
    end

    titles = Nav.sections("dev") |> Enum.map(&elem(&1, 0))
    assert titles == [nil, "Observability", "Components", "Configuration", "Other"]
    assert Enum.find(Nav.items("dev"), &(&1.key == "tinctures")).label == "Tinctures"
  end

  test "an unknown mode is dev, and ids keep the sidebar's spelling" do
    assert Nav.items(nil) == Nav.items("dev")
    assert Nav.dom_id("nav", "api_keys") == "nav-api-keys"
    assert Nav.dom_id("drawer-nav", "mcp_servers") == "drawer-nav-mcp-servers"
  end

  test "every nav destination is a routed page" do
    # The sidebar, the drawer and the palette all derive from Nav; a nav
    # item whose path the router does not serve is a dead link on every
    # one of them. Dev mode is the full set.
    route_paths =
      EmissaryWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)
      |> MapSet.new()

    for item <- Nav.items("dev") do
      expected = if item.scope == :global, do: item.path, else: "/a/:athanor" <> item.path

      assert MapSet.member?(route_paths, expected),
             "nav item #{item.key} points at #{item.path}, but no route serves #{expected}"
    end
  end

  test "a link is focused on the athanor unless the page is global — the chat is" do
    chat = Enum.find(Nav.items("lite"), &(&1.key == "chat"))
    aqua = Enum.find(Nav.items("lite"), &(&1.key == "aqua"))

    assert chat.scope == :global
    assert Nav.href(chat, "home") == "/chat"
    assert aqua.scope == :athanor
    assert Nav.href(aqua, "home") == "/a/home/aqua"

    # A bare path decides the same way — the palette and an intent hand
    # one in — and a query string does not change the answer.
    assert Nav.href("/chat", "home") == "/chat"
    assert Nav.href("/chat?a=home&c=conv_1", "home") == "/chat?a=home&c=conv_1"
    assert Nav.href("/aqua", "home") == "/a/home/aqua"
    assert Nav.href("/executions?id=exec_1", "home") == "/a/home/executions?id=exec_1"
  end

  test "an item's scope is derived from Cyfr.GlobalPages, the one list the engine reads too" do
    for item <- Nav.items("dev") do
      expected = if Cyfr.GlobalPages.global?(item.path), do: :global, else: :athanor
      assert item.scope == expected, "#{item.key} is #{item.scope}, the list says #{expected}"
    end

    # Every global page is a nav item — the list names pages, not stray paths.
    paths = Enum.map(Nav.items("dev"), & &1.path)
    for path <- Cyfr.GlobalPages.paths(), do: assert(path in paths)
  end
end
