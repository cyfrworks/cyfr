# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Nav do
  @moduledoc """
  The pages of an athanor, once: what the sidebar (dev), the drawer (both
  modes) and the command palette list, and in which mode.

  `lite` is the chat and a drawer off it — apps, members, Connections,
  Agents, schedules, webhooks, MCP servers, settings, legal. `dev` adds the
  ops surfaces, sectioned. Keys are the pages' `active_nav` values; the
  DOM id a surface renders is `<prefix>-<key>` with underscores as hyphens.
  """

  alias Prism.Labels

  @type item :: %{
          key: String.t(),
          label: String.t(),
          path: String.t(),
          icon: String.t(),
          section: atom(),
          modes: [String.t()]
        }

  @both ~w(lite dev)
  @dev ~w(dev)

  # In dev order; the lite order is its own list below.
  @items [
    %{key: "chat", label: "Chat", path: "", icon: "play", section: :top, modes: @both},
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
      key: "connections",
      label: "Connections",
      path: "/connections",
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

  @lite_order ~w(chat agents tinctures members connections schedules webhooks mcp_servers settings legal)

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

  defp resolve(%{label: noun} = item, mode) when is_atom(noun),
    do: %{item | label: Labels.label(noun, mode)}

  defp resolve(item, _mode), do: item
end
