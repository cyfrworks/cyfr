# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Layouts do
  @moduledoc """
  Layout components for Prism.

  The root HTML skeleton and the app layout: the topbar (the chrome — brand,
  the athanor switcher, the drawer button, the person), a sidebar in `dev`,
  a drawer off the page in both modes (the whole navigation on a phone, the
  lite navigation everywhere), and the content area.
  """

  use PrismWeb, :html

  alias Phoenix.LiveView.JS
  alias PrismWeb.Nav

  embed_templates "layouts/*"

  @doc "The dev sidebar: every page of the mode, sectioned. Hidden below `lg`."
  attr :mode, :string, required: true
  attr :athanor_route, :string, default: nil
  attr :active_nav, :string, default: nil

  def sidebar(assigns) do
    assigns = assign(assigns, :sections, Nav.sections(assigns.mode))

    ~H"""
    <nav class="hidden lg:flex lg:flex-shrink-0">
      <div class="flex w-64 flex-col border-r border-gray-800 bg-gray-900">
        <div class="flex flex-1 flex-col overflow-y-auto pt-3 pb-4">
          <nav class="flex-1 space-y-1 px-3">
            <%= for {title, items} <- @sections do %>
              <div :if={title} class="pt-4 pb-1">
                <p class="px-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
                  {title}
                </p>
              </div>
              <.nav_link
                :for={item <- items}
                id={Nav.dom_id("nav", item.key)}
                href={PrismWeb.Focus.path(@athanor_route, item.path)}
                icon={item.icon}
                label={item.label}
                active={@active_nav == item.key}
              />
            <% end %>
          </nav>
        </div>
      </div>
    </nav>
    """
  end

  @doc """
  The drawer off the page: the mode's pages, a search row, and New group….
  Stateless — opened and closed by `Phoenix.LiveView.JS`, rendered hidden
  by every page, so navigating away closes it.
  """
  attr :mode, :string, required: true
  attr :athanor_route, :string, default: nil
  attr :active_nav, :string, default: nil

  def drawer(assigns) do
    assigns = assign(assigns, :sections, Nav.sections(assigns.mode))

    ~H"""
    <div id="drawer" class="hidden fixed inset-0 z-40" role="dialog" aria-modal="true">
      <div class="absolute inset-0 bg-black/60" phx-click={hide_drawer()}></div>
      <div class="absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col border-r border-gray-800 bg-gray-900 shadow-xl">
        <div class="flex h-12 items-center justify-between border-b border-gray-800 px-4">
          <span class="text-xs font-semibold uppercase tracking-wider text-gray-500">Menu</span>
          <button
            type="button"
            phx-click={hide_drawer()}
            class="rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
            aria-label="Close menu"
          >
            ×
          </button>
        </div>
        <nav class="flex-1 space-y-1 overflow-y-auto p-3">
          <button
            type="button"
            id="drawer-search"
            phx-click={hide_drawer() |> JS.push("toggle", target: "#command-palette")}
            class="flex w-full items-center gap-3 rounded-md px-3 py-2 text-sm text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          >
            <.icon name="grid" class="h-5 w-5 text-gray-500" /> Search…
            <span class="ml-auto text-[10px] text-gray-600">⌘⇧K</span>
          </button>
          <%= for {title, items} <- @sections do %>
            <div :if={title} class="pt-4 pb-1">
              <p class="px-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
                {title}
              </p>
            </div>
            <.link
              :for={item <- items}
              id={Nav.dom_id("drawer-nav", item.key)}
              navigate={PrismWeb.Focus.path(@athanor_route, item.path)}
              class={[
                "flex items-center gap-3 rounded-md px-3 py-2 text-sm",
                if(@active_nav == item.key,
                  do: "bg-gray-800 text-white",
                  else: "text-gray-300 hover:bg-gray-800/60 hover:text-white"
                )
              ]}
            >
              <.icon name={item.icon} class="h-5 w-5 text-gray-500" />
              {item.label}
            </.link>
          <% end %>
          <div class="pt-4 pb-1">
            <p class="px-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
              Athanors
            </p>
          </div>
          <button
            type="button"
            id="drawer-new-group"
            phx-click={
              hide_drawer()
              |> JS.push("toggle_popover", value: %{name: "athanors"}, target: "#topbar")
            }
            class="flex w-full items-center gap-3 rounded-md px-3 py-2 text-sm text-gray-300 hover:bg-gray-800/60 hover:text-white"
          >
            <.icon name="user" class="h-5 w-5 text-gray-500" /> New group…
          </button>
        </nav>
      </div>
    </div>
    """
  end

  defp hide_drawer, do: JS.hide(to: "#drawer")
end
