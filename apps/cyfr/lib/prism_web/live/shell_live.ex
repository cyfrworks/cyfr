defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  require Logger

  @moduledoc """
  Tab-based shell for Prism apps.

  One app visible at a time, all open tabs kept alive in DOM.
  Hosts both native LiveView apps and sandboxed iframe apps.
  """

  @native_apps %{
    "dashboard" => %{module: PrismWeb.DashboardLive, title: "Dashboard", icon: "home"},
    "executions" => %{module: PrismWeb.ExecutionsLive, title: "Executions", icon: "play"},
    "logs" => %{module: PrismWeb.LogsLive, title: "Logs", icon: "document"},
    "components" => %{module: PrismWeb.ComponentsLive, title: "Components", icon: "cube"},
    "builds" => %{module: PrismWeb.BuildsLive, title: "Builds", icon: "wrench"},
    "secrets" => %{module: PrismWeb.SecretsLive, title: "Secrets", icon: "key"},
    "keys" => %{module: PrismWeb.ApiKeysLive, title: "API Keys", icon: "lock"},
    "schedules" => %{module: PrismWeb.SchedulesLive, title: "Schedules", icon: "clock"},
    "settings" => %{module: PrismWeb.SettingsLive, title: "Settings", icon: "cog"},
    "agent" => %{module: PrismWeb.AgentLive, title: "Agent", icon: "play"}
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Prism Shell")
      |> assign(:tabs, [])
      |> assign(:active_tab, nil)
      |> assign(:tab_counter, 0)
      |> assign(:launcher_open, false)
      |> assign(:viewport, %{width: 1280, height: 800})
      |> assign(:native_apps, @native_apps)
      |> assign(:iframe_apps, [])

    socket =
      if connected?(socket) do
        load_iframe_apps(socket)
      else
        socket
      end

    {:ok, socket, layout: {PrismWeb.Layouts, :shell}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if connected?(socket) && socket.assigns.tabs == [] do
        app = params["app"] || "dashboard"
        open_tab(socket, app)
      else
        socket
      end

    {:noreply, socket}
  end

  # -- Tab Management --

  @impl true
  def handle_event("open_app", %{"app" => app_id}, socket) do
    {:noreply, open_tab(socket, app_id)}
  end

  def handle_event("switch_tab", %{"id" => tab_id}, socket) do
    {:noreply, assign(socket, :active_tab, tab_id)}
  end

  def handle_event("close_tab", %{"id" => tab_id}, socket) do
    tabs = Enum.reject(socket.assigns.tabs, &(&1.id == tab_id))

    active =
      if socket.assigns.active_tab == tab_id do
        case tabs do
          [] -> nil
          remaining ->
            # Find the tab that was adjacent to the closed one
            old_idx = Enum.find_index(socket.assigns.tabs, &(&1.id == tab_id)) || 0
            new_idx = min(old_idx, length(remaining) - 1)
            Enum.at(remaining, new_idx).id
        end
      else
        socket.assigns.active_tab
      end

    {:noreply, assign(socket, tabs: tabs, active_tab: active)}
  end

  # -- Launcher --

  def handle_event("toggle_launcher", _params, socket) do
    {:noreply, assign(socket, :launcher_open, !socket.assigns.launcher_open)}
  end

  def handle_event("close_launcher", _params, socket) do
    {:noreply, assign(socket, :launcher_open, false)}
  end

  # -- Responsive --

  def handle_event("viewport_changed", %{"width" => w, "height" => h}, socket) do
    {:noreply, assign(socket, :viewport, %{width: w, height: h})}
  end

  # -- iframe bridge --

  def handle_event("iframe_message", %{"window_id" => tab_id, "message" => msg}, socket) do
    handle_iframe_message(socket, tab_id, msg)
  end

  def handle_event("iframe_message", _params, socket) do
    {:noreply, socket}
  end

  # -- Private Helpers --

  defp open_tab(socket, app_id) do
    # If this app is already open, switch to it
    case Enum.find(socket.assigns.tabs, &(&1.app_id == app_id)) do
      %{id: existing_id} ->
        socket
        |> assign(:active_tab, existing_id)
        |> assign(:launcher_open, false)

      nil ->
        {type, app_info} = resolve_app(socket, app_id)
        counter = socket.assigns.tab_counter + 1
        tab_id = "tab_#{counter}"

        tab = %{
          id: tab_id,
          app_id: app_id,
          type: type,
          title: app_info.title,
          icon: app_info.icon
        }

        tab =
          case type do
            :native -> Map.put(tab, :module, app_info.module)
            :iframe -> Map.merge(tab, %{url: app_info.url, manifest: app_info[:manifest]})
          end

        socket
        |> assign(:tabs, socket.assigns.tabs ++ [tab])
        |> assign(:active_tab, tab_id)
        |> assign(:tab_counter, counter)
        |> assign(:launcher_open, false)
    end
  end

  defp resolve_app(socket, app_id) do
    case Map.get(@native_apps, app_id) do
      nil ->
        case Enum.find(socket.assigns.iframe_apps, &(&1.id == app_id)) do
          nil ->
            {:native, Map.get(@native_apps, "dashboard")}

          iframe_app ->
            {:iframe,
             %{
               title: iframe_app.title,
               icon: iframe_app.icon,
               url: iframe_app.url,
               manifest: iframe_app[:manifest]
             }}
        end

      native_def ->
        {:native, native_def}
    end
  end

  defp load_iframe_apps(socket) do
    case Code.ensure_loaded(Prism.AppRegistry) do
      {:module, _} ->
        apps =
          Prism.AppRegistry.list_apps()
          |> Enum.map(fn app ->
            manifest = app.manifest
            app_config = manifest["app"] || %{}

            %{
              id: "iframe_#{app.name}",
              name: app.name,
              title: manifest["description"] || app.name,
              icon: app_config["icon"] || "cube",
              url: app.entry_url,
              manifest: manifest
            }
          end)

        assign(socket, :iframe_apps, apps)

      _ ->
        socket
    end
  end

  defp handle_iframe_message(socket, tab_id, %{"type" => "cyfr:request"} = msg) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.type == :iframe do
      case msg["action"] do
        "tool_call" ->
          handle_tool_call(socket, tab_id, tab, msg)

        "set_title" ->
          tabs =
            Enum.map(socket.assigns.tabs, fn t ->
              if t.id == tab_id,
                do: Map.put(t, :title, msg["payload"]["title"] || t.title),
                else: t
            end)

          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}

          {:noreply,
           socket |> assign(:tabs, tabs) |> push_event("iframe_response:#{tab_id}", response)}

        "close" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          socket = push_event(socket, "iframe_response:#{tab_id}", response)
          handle_event("close_tab", %{"id" => tab_id}, socket)

        "ready" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}

        "get_context" ->
          response = %{
            type: "cyfr:response",
            id: msg["id"],
            result: %{app_id: tab.app_id, window_id: tab_id}
          }

          {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}

        _ ->
          error_response = %{
            type: "cyfr:response",
            id: msg["id"],
            error: "unknown_action"
          }

          {:noreply, push_event(socket, "iframe_response:#{tab_id}", error_response)}
      end
    else
      if msg["id"] do
        response = %{type: "cyfr:response", id: msg["id"], error: "window_not_found"}
        {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}
      else
        {:noreply, socket}
      end
    end
  end

  defp handle_iframe_message(socket, _tab_id, _msg), do: {:noreply, socket}

  defp handle_tool_call(socket, tab_id, tab, msg) do
    tool = get_in(msg, ["payload", "tool"])
    args = get_in(msg, ["payload", "args"]) || %{}

    allowed = get_in(tab, [:manifest, "setup", "policy", "allowed_tools"]) || []
    Logger.info("iframe tool_call: app=#{tab.app_id} tool=#{tool}")

    if tool_allowed?(tool, allowed) do
      case call_tool(socket, tool, args) do
        {:ok, result} ->
          response = %{type: "cyfr:response", id: msg["id"], result: result}
          {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}

        {:error, reason} ->
          Logger.warning(
            "iframe tool_call failed: app=#{tab.app_id} tool=#{tool} error=#{inspect(reason)}"
          )

          response = %{type: "cyfr:response", id: msg["id"], error: "tool_call_failed"}
          {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}
      end
    else
      Logger.warning("iframe tool_call denied: app=#{tab.app_id} tool=#{tool}")

      response = %{
        type: "cyfr:response",
        id: msg["id"],
        error: "tool_not_allowed"
      }

      {:noreply, push_event(socket, "iframe_response:#{tab_id}", response)}
    end
  end

  defp tool_allowed?(_tool, ["*"]), do: true

  defp tool_allowed?(tool, allowed) do
    normalized = String.replace(tool, "/", ".")
    Enum.any?(allowed, fn a -> a == tool || String.replace(a, "/", ".") == normalized end)
  end

  def all_apps(assigns) do
    native =
      @native_apps
      |> Enum.map(fn {id, info} ->
        %{id: id, title: info.title, icon: info.icon, type: :native}
      end)
      |> Enum.sort_by(& &1.title)

    iframe =
      assigns.iframe_apps
      |> Enum.map(fn app ->
        %{id: app.id, title: app.title, icon: app.icon, type: :iframe}
      end)

    native ++ iframe
  end

  # -- Render --

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :all_apps, all_apps(assigns))

    ~H"""
    <div
      id="shell"
      class="relative w-screen h-screen overflow-hidden bg-gray-950 flex flex-col"
      phx-hook="ShellViewport"
    >
      <%!-- Content area --%>
      <div class="relative flex-1 overflow-hidden">
        <div :if={@tabs == []} class="flex flex-col items-center justify-center h-full text-gray-500 gap-4">
          <svg class="w-12 h-12 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
              d="M4 6h4v4H4V6zm6 0h4v4h-4V6zm6 0h4v4h-4V6zM4 12h4v4H4v-4zm6 0h4v4h-4v-4zm6 0h4v4h-4v-4z" />
          </svg>
          <p class="text-sm">No apps open</p>
          <button phx-click="toggle_launcher" class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-gray-300 rounded-lg text-sm transition-colors">
            Open Launcher
          </button>
        </div>
        <%= for tab <- @tabs do %>
          <div class={["absolute inset-0", if(tab.id != @active_tab, do: "hidden")]}>
            <%= if tab.type == :native do %>
              {live_render(@socket, tab.module, id: tab.id, session: %{"shell" => true, "session_token" => @session_token})}
            <% else %>
              <iframe
                id={"iframe_#{tab.id}"}
                src={tab.url}
                sandbox="allow-scripts allow-same-origin"
                class="w-full h-full border-0"
                phx-hook="IframeBridge"
                data-window-id={tab.id}
              />
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Tab dock --%>
      <div class="flex items-center h-12 bg-gray-900/80 backdrop-blur-md border-t border-gray-700/50 px-2 shrink-0">
        <%!-- Launcher button --%>
        <button
          phx-click="toggle_launcher"
          class="flex items-center justify-center w-9 h-9 rounded-lg hover:bg-gray-700/50 transition-colors mr-2 shrink-0"
          aria-label="Launcher"
        >
          <svg class="w-5 h-5 text-gray-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
              d="M4 6h4v4H4V6zm6 0h4v4h-4V6zm6 0h4v4h-4V6zM4 12h4v4H4v-4zm6 0h4v4h-4v-4zm6 0h4v4h-4v-4z" />
          </svg>
        </button>

        <div class="w-px h-6 bg-gray-700 mr-2 shrink-0" />

        <%!-- Tabs --%>
        <div class="flex items-center gap-1 flex-1 overflow-x-auto">
          <%= for tab <- @tabs do %>
            <div class={[
              "group flex items-center gap-2 px-3 py-1.5 rounded-lg transition-colors cursor-pointer shrink-0",
              if(tab.id == @active_tab,
                do: "bg-blue-600/30 text-blue-300",
                else: "text-gray-400 hover:bg-gray-700/50 hover:text-gray-200"
              )
            ]} phx-click="switch_tab" phx-value-id={tab.id}>
              <.icon name={tab.icon} class="h-4 w-4" />
              <span class="text-xs truncate max-w-[100px]">{tab.title}</span>
              <button
                phx-click="close_tab"
                phx-value-id={tab.id}
                class="ml-1 opacity-0 group-hover:opacity-100 text-gray-500 hover:text-gray-200 transition-opacity"
                aria-label={"Close #{tab.title}"}
              >
                <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
          <% end %>
        </div>

        <%!-- Right section --%>
        <div class="flex items-center gap-3 ml-2 shrink-0">
          <span :if={assigns[:current_user]} class="text-xs text-gray-500 truncate max-w-[120px]">
            {@current_user.email || @current_user.id}
          </span>
        </div>
      </div>

      <%!-- Launcher Overlay --%>
      <.launcher_overlay :if={@launcher_open} apps={@all_apps} />
    </div>
    """
  end

  # -- Launcher Overlay --

  defp launcher_overlay(assigns) do
    ~H"""
    <div
      class="absolute inset-0 z-[10000] flex items-center justify-center"
      phx-click="close_launcher"
    >
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" />

      <div
        class="relative z-10 bg-gray-900/95 rounded-2xl border border-gray-700/50 p-6 max-h-[80vh] overflow-y-auto max-w-2xl w-full mx-4"
        phx-click-away="close_launcher"
      >
        <h2 class="text-lg font-semibold text-white mb-4">Apps</h2>
        <div class="grid grid-cols-3 sm:grid-cols-4 lg:grid-cols-6 gap-4">
          <%= for app <- @apps do %>
            <button
              phx-click="open_app"
              phx-value-app={app.id}
              class="flex flex-col items-center gap-2 p-4 rounded-xl hover:bg-gray-800/80 transition-colors group"
            >
              <div class="w-12 h-12 rounded-xl bg-gray-800 group-hover:bg-gray-700 flex items-center justify-center transition-colors">
                <.icon name={app.icon} class="h-6 w-6 text-gray-300" />
              </div>
              <span class="text-xs text-gray-400 group-hover:text-gray-200 text-center truncate w-full">
                {app.title}
              </span>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
