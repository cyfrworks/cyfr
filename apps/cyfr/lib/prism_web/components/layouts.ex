# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Layouts do
  @moduledoc """
  Layout components for Prism.

  Two root skeletons and the app layout. `root` is the bare document the
  sign-in pages and the console's other pages render in. `desktop` is the
  `:athanor` session's: the person's desktop (`PrismWeb.ShellLive`) as a
  LiveView of its own, filling the screen under the top bar, beside the
  page's LiveView, which a move between the session's pages replaces while
  the desktop and its frames stay as they are.

  The app layout is the page's layer over the desktop: the top bar (the
  chrome — brand, the drawer button, the person), the command palette,
  the flash, and the page. A Dashboard page stands as an overlay over the
  desktop's apps' area, from the top bar to the shelf, which stays in
  reach: a panel inset on the desk, the whole area in the hand, with the
  page list (a sidebar in `dev` on wide screens, the drawer in both UI
  modes) and a close that returns to the desktop (`PrismWeb.DesktopLive`).
  A page that draws nothing over the desktop (`overlay: false`, the
  desktop's own address and the forwards to it) has no overlay. The layer
  takes no pointer where it draws nothing, so the desktop under it stays
  live.
  """

  use PrismWeb, :html

  alias Phoenix.LiveView.JS
  alias PrismWeb.Nav

  embed_templates "layouts/*"

  @doc """
  The request as the desktop is rendered from it: without the page's route,
  its parameters and its live session, whose mount hooks are the page's.
  The desktop is no route's (`PrismWeb.ShellLive` mounts its own hooks),
  so its first render runs what its connected mount runs, and nothing the
  page's address names.
  """
  @spec desktop_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def desktop_conn(%Plug.Conn{} = conn) do
    %{conn | params: %{}, path_params: %{}}
    |> Plug.Conn.put_private(:phoenix_live_view, nil)
  end

  @doc "The document's head, one for both root skeletons."
  attr :page_title, :string, default: nil

  def document_head(assigns) do
    ~H"""
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="csrf-token" content={get_csrf_token()} />
      <.live_title default="CYFR">
        {@page_title}
      </.live_title>
      <link rel="icon" type="image/jpeg" href={~p"/images/logo.jpg"} />
      <link rel="apple-touch-icon" href={~p"/images/logo.jpg"} />
      <link rel="manifest" href="/manifest.webmanifest" />
      <meta name="theme-color" content="#030712" />
      <meta property="og:image" content={~p"/images/logo.jpg"} />
      <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
      <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
      </script>
    </head>
    """
  end

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
                href={Nav.href(item, @athanor_route)}
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
  The drawer off the page: the mode's pages and a search row.
  Stateless — opened and closed by `Phoenix.LiveView.JS`, rendered hidden
  by every page, so navigating away closes it.
  """
  attr :mode, :string, required: true
  attr :athanor_route, :string, default: nil
  attr :active_nav, :string, default: nil

  def drawer(assigns) do
    assigns = assign(assigns, :sections, Nav.sections(assigns.mode))

    ~H"""
    <div
      id="drawer"
      class="hidden fixed inset-0 z-[66] pointer-events-auto"
      role="dialog"
      aria-modal="true"
    >
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
              navigate={Nav.href(item, @athanor_route)}
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
        </nav>
      </div>
    </div>
    """
  end

  defp hide_drawer, do: JS.hide(to: "#drawer")
end
