defmodule PrismWeb.CommandPaletteLiveComponent do
  @moduledoc """
  Cmd+K command palette — fuzzy-search across navigation, recent activity,
  components, and tinctures.

  Stateless modal LiveComponent rendered from the app layout. The companion
  JS hook (`assets/js/hooks/command_palette.js`) listens for the keyboard
  shortcut and pushes `toggle` / `close` events here.

  All backing queries pass through tenant-scoped APIs — `Arca.McpLog.list`
  requires `org_id` + `project_id`, and Compendium / TinctureRegistry
  lookups use the user's `Sanctum.Context`. The palette never calls
  platform-scope variants. Action invocation goes through
  `Emissary.MCP.ToolRegistry.call/3` with the user's context — same authz
  path as a normal page interaction.

  In Phase 3, Cmd+K rebinds to the AQUA overlay; Cmd+Shift+K (or Cmd+P)
  inherits this palette.
  """

  use PrismWeb, :live_component

  require Logger

  @max_recent 8

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:items, [])
     |> assign(:loading, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    if socket.assigns.open do
      {:noreply, close(socket)}
    else
      {:noreply, socket |> assign(:open, true) |> load_items()}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> load_items()}
  end

  def handle_event("pick", %{"to" => path}, socket) when is_binary(path) and path != "" do
    {:noreply, socket |> close() |> push_navigate(to: path)}
  end

  def handle_event("pick", _params, socket), do: {:noreply, close(socket)}

  defp close(socket) do
    socket
    |> assign(:open, false)
    |> assign(:query, "")
    |> assign(:items, [])
  end

  # ============================================================================
  # Item assembly
  # ============================================================================

  defp load_items(socket) do
    ctx = socket.assigns[:context]

    items =
      if ctx do
        nav_items() ++
          context_actions(socket.assigns[:active_context]) ++
          recent_request_items(ctx) ++
          component_items(ctx) ++
          tincture_items(ctx)
      else
        nav_items()
      end

    filtered = filter_items(items, socket.assigns.query)

    assign(socket, :items, filtered)
  end

  defp nav_items do
    [
      nav_item("Agent", "/agent", "play"),
      nav_item("Activity", "/activity", "play"),
      nav_item("Executions", "/executions", "cube"),
      nav_item("Schedules", "/schedules", "clock"),
      nav_item("Components", "/components", "cube"),
      nav_item("Builds", "/builds", "wrench"),
      nav_item("Registry", "/registry", "globe"),
      nav_item("Tinctures", "/tinctures", "palette"),
      nav_item("Secrets", "/secrets", "key"),
      nav_item("API Keys", "/api-keys", "lock"),
      nav_item("MCP Servers", "/mcp-servers", "globe"),
      nav_item("Settings", "/settings", "cog"),
      nav_item("Reports", "/reports", "flag"),
      nav_item("Legal", "/legal", "document")
    ]
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
        to: "/activity",
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
        label: "Open Tinctures",
        hint: id,
        to: "/tinctures",
        icon: "palette",
        keywords: "open tincture #{id}"
      }
    ]
  end

  defp context_actions(_), do: []

  defp recent_request_items(ctx) do
    case Emissary.MCP.ToolRegistry.call("mcp_log", ctx, %{
           "action" => "list",
           "limit" => @max_recent
         }) do
      {:ok, %{logs: logs}} when is_list(logs) ->
        Enum.map(logs, fn log ->
          %{
            kind: :recent_request,
            label: "#{log[:tool] || "mcp"} / #{log[:action] || "?"}",
            hint: short(log[:id]),
            to: "/activity",
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

  defp component_items(ctx) do
    case Emissary.MCP.ToolRegistry.call("component", ctx, %{
           "action" => "list",
           "limit" => @max_recent
         }) do
      {:ok, %{components: list}} when is_list(list) ->
        Enum.map(list, fn comp ->
          ref = comp[:reference] || comp["reference"] || ""

          %{
            kind: :component,
            label: ref,
            hint: comp[:component_type] || comp["component_type"] || "",
            to: "/components/#{URI.encode(ref)}",
            icon: "cube",
            keywords: ("component " <> ref) |> String.downcase()
          }
        end)

      _ ->
        []
    end
  end

  defp tincture_items(ctx) do
    try do
      Prism.TinctureRegistry.list_tinctures(ctx)
      |> Enum.take(@max_recent)
      |> Enum.map(fn t ->
        %{
          kind: :tincture,
          label: t.title || "#{t.publisher}.#{t.name}",
          hint: "tincture",
          to: "/tinctures",
          icon: "palette",
          keywords:
            ["tincture", t.publisher, t.name, t.title]
            |> Enum.filter(& &1)
            |> Enum.join(" ")
            |> String.downcase()
        }
      end)
    rescue
      _ -> []
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

  defp short(nil), do: ""
  defp short(s) when is_binary(s) and byte_size(s) > 16, do: String.slice(s, 0, 16) <> "…"
  defp short(s), do: to_string(s)

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
        class="fixed inset-0 z-50 flex items-start justify-center bg-black/60 pt-[15vh] px-4"
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
              autofocus
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
            <span>Cmd+K toggle</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

end
