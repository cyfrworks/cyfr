# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CommandPaletteLiveComponent do
  @moduledoc """
  The command palette (⌘⇧K, the topbar's search icon, the drawer's
  Search… row) — fuzzy-search across the mode's pages and, in `dev`, recent
  activity, components and tinctures.

  Stateless modal LiveComponent rendered from the app layout. The companion
  JS hook (`assets/js/hooks/command_palette.js`) listens for the keyboard
  shortcut and pushes `toggle` / `close` events here; the click triggers
  push the same events by target.

  All backing queries pass through tenant-scoped APIs — the `mcp_log`
  tool's `list` reads the request log under the user's `Sanctum.Context`,
  and Compendium / TinctureRegistry lookups use the same context. The
  palette never calls platform-scope variants. Action invocation goes
  through `Sanctum.Gate.call_external/4` with the user's context — same
  authz path as a normal page interaction.
  """

  use PrismWeb, :live_component

  require Logger

  @max_recent 8
  # The installed components a typed search shows at most, as the
  # component domain matches them.
  @max_matches 50

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:items, [])
     |> assign(:all_items, [])
     |> assign(:components?, false)
     |> assign(:components, [])
     |> assign(:loading, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      if socket.assigns.open do
        {:noreply, close(socket)}
      else
        {:noreply, socket |> assign(:open, true) |> load_items()}
      end
    end)
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  # The pages, requests and tinctures are loaded once, on open, and only
  # filtered while typing. Installed components are the component domain's
  # to match (`component.search` over the installed ones), so a search
  # finds one by its name however many are installed.
  def handle_event("search", %{"value" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(:query, query) |> find_components() |> refilter()}
  end

  # Every target is a page path; `Nav.href/2` decides whether the focus
  # prefix goes on it. `@athanor_route` is already in assigns —
  # `Focus.route_of/1` re-read it from the DB on every pick.
  def handle_event("pick", %{"to" => path}, socket) when is_binary(path) do
    to = PrismWeb.Nav.href(path, socket.assigns.athanor_route)
    {:noreply, socket |> close() |> push_navigate(to: to)}
  end

  def handle_event("pick", _params, socket), do: {:noreply, close(socket)}

  defp close(socket) do
    socket
    |> assign(:open, false)
    |> assign(:query, "")
    |> assign(:items, [])
    |> assign(:all_items, [])
    |> assign(:components, [])
  end

  # ============================================================================
  # Item assembly
  # ============================================================================

  # The mode's pages always; the developer's lookups — recent requests,
  # components — only where those pages exist to open. Before anything is
  # typed the components are the newest few.
  defp load_items(socket) do
    ctx = socket.assigns[:context]
    mode = Prism.Labels.mode(socket.assigns[:ui_mode])

    items =
      cond do
        is_nil(ctx) ->
          nav_items(mode)

        Prism.Labels.dev?(mode) ->
          nav_items(mode) ++
            context_actions(socket.assigns[:active_context]) ++
            recent_request_items(ctx) ++
            tincture_items(ctx)

        true ->
          nav_items(mode) ++ tincture_items(ctx)
      end

    socket
    |> assign(:all_items, items)
    |> assign(:components?, not is_nil(ctx) and Prism.Labels.dev?(mode))
    |> find_components()
    |> refilter()
  end

  defp refilter(socket) do
    %{all_items: items, query: query, components: components} = socket.assigns
    assign(socket, :items, filter_items(items, query) ++ components)
  end

  defp find_components(%{assigns: %{components?: false}} = socket),
    do: assign(socket, :components, [])

  defp find_components(socket) do
    ctx = socket.assigns.context

    case String.trim(socket.assigns.query) do
      "" ->
        assign(
          socket,
          :components,
          component_items(ctx, "component/list", %{"limit" => @max_recent})
        )

      typed ->
        args = %{"query" => typed, "source" => "local", "limit" => @max_matches}
        assign(socket, :components, component_items(ctx, "component/search", args))
    end
  end

  defp nav_items(mode) do
    for item <- PrismWeb.Nav.items(mode), do: nav_item(item.label, item.path, item.icon)
  end

  defp nav_item(label, path, icon) do
    %{
      kind: :nav,
      label: label,
      hint: path,
      to: path,
      icon: icon,
      keywords: [label, path] |> Enum.join(" ") |> String.downcase()
    }
  end

  # Context-aware actions derived from the active focused resource.
  defp context_actions(%{focused_resource: {:request, id}}) do
    [
      %{
        kind: :action,
        label: "Open this request",
        hint: id,
        to: "/activities",
        icon: "play",
        keywords: "open request #{id}"
      }
    ]
  end

  defp context_actions(%{focused_resource: {:component, ref}}) do
    [
      %{
        kind: :action,
        label: "Open this component",
        hint: ref,
        to: "/components/#{URI.encode(ref)}",
        icon: "cube",
        keywords: "open component #{ref}"
      }
    ]
  end

  defp context_actions(%{focused_resource: {:tincture, id}}) do
    [
      %{
        kind: :action,
        label: "Open the desktop",
        hint: id,
        to: "/",
        icon: "palette",
        keywords: "open tincture #{id}"
      }
    ]
  end

  defp context_actions(_), do: []

  defp recent_request_items(ctx) do
    case call_tool(ctx, "mcp_log/list", %{"limit" => @max_recent}) do
      {:ok, %{logs: logs}} when is_list(logs) ->
        Enum.map(logs, fn log ->
          %{
            kind: :recent_request,
            label: "#{log[:tool] || "mcp"} / #{log[:action] || "?"}",
            hint: short(log[:id]),
            to: "/activities",
            icon: "play",
            keywords:
              ["request", log[:tool], log[:action], log[:id]]
              |> Enum.filter(& &1)
              |> Enum.join(" ")
              |> String.downcase()
          }
        end)

      _ ->
        []
    end
  end

  defp component_items(ctx, tool, args) do
    case call_tool(ctx, tool, args) do
      {:ok, %{components: list}} when is_list(list) ->
        Enum.map(list, fn comp ->
          ref = comp[:component_ref] || ""

          %{
            kind: :component,
            label: ref,
            hint: comp[:component_type] || "",
            to: "/components/#{URI.encode(ref)}",
            icon: "cube",
            keywords: ("component " <> ref) |> String.downcase()
          }
        end)

      _ ->
        []
    end
  end

  # A desktop opens the shell's chooser of desktops by its key; an app,
  # the tincture focused in the picker (`PrismWeb.DesktopLive`).
  defp tincture_path(t) do
    if Prism.Frames.canvas?(t),
      do: "/?shell=desktops",
      else:
        "/?publisher=#{URI.encode_www_form(t.publisher)}" <>
          "&tincture_name=#{URI.encode_www_form(t.name)}"
  end

  defp tincture_items(ctx) do
    try do
      Prism.TinctureRegistry.list_tinctures(ctx)
      |> Enum.map(fn t ->
        %{
          kind: :tincture,
          label: t.title || "#{t.publisher}.#{t.name}",
          hint: if(Prism.Frames.canvas?(t), do: "desktop", else: "tincture"),
          to: tincture_path(t),
          icon: "palette",
          keywords:
            ["tincture", t.publisher, t.name, t.title]
            |> Enum.filter(& &1)
            |> Enum.join(" ")
            |> String.downcase()
        }
      end)
    rescue
      # An empty palette and a broken palette look identical to the person
      # using it, so the exception at least reaches the log.
      exception ->
        Logger.warning(
          "[CommandPalette] entries could not be built: " <>
            Prima.LogFilter.format_exception(:error, exception, __STACKTRACE__)
        )

        []
    end
  end

  # ============================================================================
  # Filter
  # ============================================================================

  defp filter_items(items, ""), do: items
  defp filter_items(items, nil), do: items

  defp filter_items(items, query) do
    needle = String.downcase(query)
    Enum.filter(items, fn item -> String.contains?(item.keywords, needle) end)
  end

  # See `ExecutionsLive.short/1`: one truncation, in one unit.
  defp short(nil), do: ""
  defp short(s), do: truncate(s, 16)

  defp kind_label(:nav), do: "Page"
  defp kind_label(:action), do: "Action"
  defp kind_label(:recent_request), do: "Request"
  defp kind_label(:component), do: "Component"
  defp kind_label(:tincture), do: "Tincture"

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CommandPalette"
      data-open={if @open, do: "true", else: "false"}
    >
      <div
        :if={@open}
        class="fixed inset-0 z-[80] flex items-start justify-center bg-black/60 pt-[15vh] px-4"
      >
        <div
          class="w-full max-w-xl rounded-lg border border-gray-700 bg-gray-900 shadow-2xl"
          phx-click-away="close"
          phx-target={@myself}
        >
          <div class="border-b border-gray-800 px-4 py-3">
            <input
              type="text"
              placeholder="Search pages, components, requests…  (Esc to close)"
              value={@query}
              phx-keyup="search"
              phx-target={@myself}
              phx-debounce="120"
              class="w-full bg-transparent text-sm text-white placeholder-gray-500 outline-none"
            />
          </div>

          <ul class="max-h-[50vh] overflow-y-auto py-1">
            <li :if={@items == []} class="px-4 py-6 text-center text-sm text-gray-500">
              No matches.
            </li>
            <%= for item <- @items do %>
              <li>
                <button
                  type="button"
                  class="flex w-full items-center gap-3 px-4 py-2 text-left text-sm text-gray-200 hover:bg-gray-800"
                  phx-click="pick"
                  phx-value-to={item.to}
                  phx-target={@myself}
                >
                  <.icon name={item.icon} class="h-4 w-4 text-gray-500" />
                  <span class="flex-1 truncate">{item.label}</span>
                  <span class="text-xs text-gray-500 truncate">{item.hint}</span>
                  <span class="rounded bg-gray-800 px-1.5 py-0.5 text-[10px] uppercase tracking-wider text-gray-500">
                    {kind_label(item.kind)}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>

          <div class="flex items-center justify-between border-t border-gray-800 px-4 py-2 text-[11px] text-gray-500">
            <span>↑ ↓ navigate</span>
            <span>⌘⇧K toggle</span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
