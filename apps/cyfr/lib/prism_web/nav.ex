# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Nav do
  @moduledoc """
  The pages of an athanor, once: what the sidebar (dev), the drawer (both
  modes) and the command palette list, and in which mode.

  `lite` is the chat and a drawer off it — AQUA, apps, members, the
  Vault, schedules, webhooks, MCP servers, settings, legal. `dev` adds the
  ops surfaces, sectioned. Keys are the pages' `active_nav` values; the
  DOM id a surface renders is `<prefix>-<key>` with underscores as hyphens.

  Two scopes. An `:athanor` page lives under `/a/<athanor>` — the
  workbench, focused on one estate. A `:global` page has no estate in its
  address — the chat, which spans every estate the person belongs to.
  Which is which is `global_pages/0`, the one list: an item's `scope` is
  derived from it, never written by hand, and `href/2` is the one place a
  path becomes a link, so no surface has to know. `page?/1` is where a
  link the assistant proposes is checked against what the router serves.
  """

  alias Prism.Labels

  @type item :: %{
          key: String.t(),
          label: String.t(),
          path: String.t(),
          icon: String.t(),
          section: atom(),
          modes: [String.t()],
          scope: :athanor | :global
        }

  @both ~w(lite dev)
  @dev ~w(dev)

  # The pages with no estate in their address. Every other page lives
  # under `/a/<athanor>`; a global page spans every estate the person
  # belongs to — the chat is one.
  @global_pages ~w(/chat)

  # In dev order; the lite order is its own list below.
  @items [
    %{key: "chat", label: "Chat", path: "/chat", icon: "play", section: :top, modes: @both},
    %{key: "aqua", label: "AQUA", path: "/aqua", icon: "user", section: :top, modes: @both},
    %{
      key: "tinctures",
      label: :tinctures,
      path: "/tinctures",
      icon: "palette",
      section: :top,
      modes: @both
    },
    %{
      key: "activities",
      label: "Activities",
      path: "/activities",
      icon: "play",
      section: :observability,
      modes: @dev
    },
    %{
      key: "executions",
      label: :executions,
      path: "/executions",
      icon: "cube",
      section: :observability,
      modes: @dev
    },
    %{
      key: "schedules",
      label: "Schedules",
      path: "/schedules",
      icon: "clock",
      section: :observability,
      modes: @both
    },
    %{
      key: "enforcements",
      label: "Enforcements",
      path: "/enforcements",
      icon: "shield",
      section: :observability,
      modes: @dev
    },
    %{
      key: "components",
      label: :components,
      path: "/components",
      icon: "cube",
      section: :components,
      modes: @dev
    },
    %{
      key: "builds",
      label: "Builds",
      path: "/builds",
      icon: "wrench",
      section: :components,
      modes: @dev
    },
    %{
      key: "registry",
      label: "Registry",
      path: "/registry",
      icon: "globe",
      section: :components,
      modes: @dev
    },
    %{
      key: "vault",
      label: "Vault",
      path: "/vault",
      icon: "key",
      section: :configuration,
      modes: @both
    },
    %{
      key: "api_keys",
      label: "API Keys",
      path: "/api-keys",
      icon: "lock",
      section: :configuration,
      modes: @dev
    },
    %{
      key: "members",
      label: "Members",
      path: "/members",
      icon: "user",
      section: :configuration,
      modes: @both
    },
    %{
      key: "webhooks",
      label: "Webhooks",
      path: "/webhooks",
      icon: "link",
      section: :configuration,
      modes: @both
    },
    %{
      key: "mcp_servers",
      label: "MCP Servers",
      path: "/mcp-servers",
      icon: "globe",
      section: :configuration,
      modes: @both
    },
    %{
      key: "settings",
      label: "Settings",
      path: "/settings",
      icon: "cog",
      section: :configuration,
      modes: @both
    },
    %{
      key: "reports",
      label: "Reports",
      path: "/reports",
      icon: "flag",
      section: :other,
      modes: @dev
    },
    %{
      key: "legal",
      label: "Legal",
      path: "/legal",
      icon: "document",
      section: :other,
      modes: @both
    }
  ]

  @lite_order ~w(chat aqua tinctures members vault schedules webhooks mcp_servers settings legal)

  @sections [
    {:top, nil},
    {:observability, "Observability"},
    {:components, "Components"},
    {:configuration, "Configuration"},
    {:other, "Other"}
  ]

  @doc "The pages a mode offers, in that mode's order, labels resolved."
  @spec items(String.t()) :: [item()]
  def items(mode) do
    mode = Labels.mode(mode)

    case mode do
      "lite" ->
        for key <- @lite_order,
            item = Enum.find(@items, &(&1.key == key)),
            do: resolve(item, mode)

      _ ->
        for item <- @items, mode in item.modes, do: resolve(item, mode)
    end
  end

  @doc """
  The pages of a mode grouped by section, `[{title | nil, [item]}]`, empty
  sections dropped. Lite is one unnamed group.
  """
  @spec sections(String.t()) :: [{String.t() | nil, [item()]}]
  def sections(mode) do
    case Labels.mode(mode) do
      "lite" ->
        [{nil, items("lite")}]

      mode ->
        items = items(mode)

        for {section, title} <- @sections,
            group = Enum.filter(items, &(&1.section == section)),
            group != [],
            do: {title, group}
    end
  end

  @doc "The DOM id a surface gives a page's link: `nav-api-keys`, `drawer-nav-chat`."
  @spec dom_id(String.t(), String.t()) :: String.t()
  def dom_id(prefix, key), do: prefix <> "-" <> String.replace(key, "_", "-")

  @doc """
  The link for a page — an item, or a bare page path (query string
  allowed): a global page is its own address; an athanor page is focused
  on `athanor_route` (`PrismWeb.Focus.path/2`).
  """
  @spec href(item() | String.t(), String.t() | nil) :: String.t()
  def href(%{path: path}, athanor_route), do: href(path, athanor_route)

  def href(path, athanor_route) when is_binary(path) do
    if global?(path),
      do: path,
      else: PrismWeb.Focus.path(athanor_route, path)
  end

  @doc "The paths of the pages that have no estate in their address."
  @spec global_pages() :: [String.t()]
  def global_pages, do: @global_pages

  @doc "Whether `path` (query string allowed) is a global page's."
  @spec global?(String.t()) :: boolean()
  def global?(path) when is_binary(path) do
    base = path |> String.split("?", parts: 2) |> hd()
    base in @global_pages
  end

  @doc """
  Whether the console serves `href` as a page: a GET route the router
  declares, resolved with its parameters — a record's own page counts —
  and not a redirect stub, which only forwards to another address. The
  query string is ignored. This is where a navigate the assistant proposes
  is mapped to a route; the engine checks a path's shape and never reads
  the router.
  """
  @spec page?(String.t()) :: boolean()
  def page?(href) when is_binary(href) do
    path = href |> String.split("?", parts: 2) |> hd()

    case Phoenix.Router.route_info(EmissaryWeb.Router, "GET", path, "") do
      %{phoenix_live_view: live} when is_tuple(live) -> not redirect_stub?(elem(live, 0))
      %{} -> true
      :error -> false
    end
  end

  # A LiveView named `…RedirectLive` only forwards to another address: a
  # navigate to it would land the browser somewhere the assistant did not
  # name, so the page it forwards to is the target, never the stub.
  defp redirect_stub?(live) when is_atom(live),
    do: live |> Atom.to_string() |> String.ends_with?("RedirectLive")

  defp resolve(%{label: noun} = item, mode) when is_atom(noun),
    do: resolve(%{item | label: Labels.label(noun, mode)}, mode)

  defp resolve(item, _mode), do: Map.put(item, :scope, scope(item.path))

  defp scope(path), do: if(global?(path), do: :global, else: :athanor)
end
