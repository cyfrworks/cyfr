# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Nav do
  @moduledoc """
  The pages of an athanor, once: what the sidebar (dev), the drawer (both
  modes) and the command palette list, and in which mode.

  `lite` is the chat and a drawer off it — apps, members, the Vault,
  Agents, schedules, webhooks, MCP servers, settings, legal. `dev` adds the
  ops surfaces, sectioned. Keys are the pages' `active_nav` values; the
  DOM id a surface renders is `<prefix>-<key>` with underscores as hyphens.

  Two scopes. An `:athanor` page lives under `/a/<athanor>` — the
  workbench, focused on one estate. A `:global` page has no estate in its
  address — the chat, which spans every estate the person belongs to
  (`Cyfr.GlobalPages` is the list the engine reads too). `href/2` is the
  one place a path becomes a link, so no surface has to know which is
  which.
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

  # In dev order; the lite order is its own list below.
  @items [
    %{
      key: "chat",
      label: "Chat",
      path: "/chat",
      icon: "play",
      section: :top,
      modes: @both,
      scope: :global
    },
    %{key: "agents", label: "Agents", path: "/agents", icon: "user", section: :top, modes: @both},
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

  @lite_order ~w(chat agents tinctures members vault schedules webhooks mcp_servers settings legal)

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
  The link for a page: a global page is its own path; an athanor page is
  focused on `athanor_route` (`PrismWeb.Focus.path/2`).
  """
  @spec href(item(), String.t() | nil) :: String.t()
  def href(%{scope: :global, path: path}, _athanor_route), do: path
  def href(%{path: path}, athanor_route), do: PrismWeb.Focus.path(athanor_route, path)

  @doc "Whether `path` is a global page's — one with no estate in its address."
  @spec global?(String.t()) :: boolean()
  defdelegate global?(path), to: Cyfr.GlobalPages

  @doc "The global pages' paths — the items marked `:global`, which `Cyfr.GlobalPages` pins."
  @spec global_paths() :: [String.t()]
  def global_paths, do: for(%{scope: :global, path: path} <- @items, do: path)

  defp resolve(%{label: noun} = item, mode) when is_atom(noun),
    do: resolve(%{item | label: Labels.label(noun, mode)}, mode)

  defp resolve(item, _mode), do: Map.put_new(item, :scope, :athanor)
end
