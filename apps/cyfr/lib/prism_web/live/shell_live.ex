defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  require Logger

  @moduledoc """
  Dual-desktop shell for Prism apps.

  Two desktops ("System" and "Apps") switchable from the dock.
  Each has a sidebar for navigation and a main content panel.
  All opened apps are kept alive in DOM via CSS hidden.
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

  @sidebar_sections [
    {nil, ["dashboard", "agent"]},
    {"Workflows", ["executions", "schedules", "logs"]},
    {"Registry", ["components", "builds"]},
    {"Security", ["secrets", "keys"]},
    {nil, ["settings"]}
  ]

  @categorized_native_apps Enum.map(@sidebar_sections, fn {label, ids} ->
                             apps = Enum.map(ids, fn id -> Map.merge(@native_apps[id], %{id: id}) end)
                             {label, apps}
                           end)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Prism Shell")
      |> assign(:desktop, :system)
      |> assign(:active_system_app, "dashboard")
      |> assign(:opened_system_apps, ["dashboard"])
      |> assign(:active_iframe_app, nil)
      |> assign(:opened_iframe_apps, [])
      |> assign(:categorized_native_apps, @categorized_native_apps)
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
      if connected?(socket) do
        case params["app"] do
          nil ->
            socket

          app_id when is_map_key(@native_apps, app_id) ->
            socket
            |> assign(:active_system_app, app_id)
            |> maybe_track_system_app(app_id)

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # -- Desktop switching --

  @impl true
  def handle_event("switch_desktop", %{"desktop" => desktop}, socket) do
    desktop = String.to_existing_atom(desktop)
    {:noreply, assign(socket, :desktop, desktop)}
  end

  # -- App selection --

  def handle_event("select_system_app", %{"app" => app_id}, socket) do
    if Map.has_key?(@native_apps, app_id) do
      socket =
        socket
        |> assign(:active_system_app, app_id)
        |> maybe_track_system_app(app_id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_iframe_app", %{"app" => app_id}, socket) do
    if Enum.any?(socket.assigns.iframe_apps, &(&1.id == app_id)) do
      socket =
        socket
        |> assign(:active_iframe_app, app_id)
        |> maybe_track_iframe_app(app_id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # -- Responsive --

  def handle_event("viewport_changed", %{"width" => w, "height" => h}, socket) do
    {:noreply, assign(socket, :viewport, %{width: w, height: h})}
  end

  # -- iframe bridge --

  def handle_event("iframe_message", %{"window_id" => app_id, "message" => msg}, socket) do
    handle_iframe_message(socket, app_id, msg)
  end

  def handle_event("iframe_message", _params, socket) do
    {:noreply, socket}
  end

  # -- Tracking helpers --

  defp maybe_track_system_app(socket, app_id) do
    if app_id in socket.assigns.opened_system_apps do
      socket
    else
      assign(socket, :opened_system_apps, socket.assigns.opened_system_apps ++ [app_id])
    end
  end

  defp maybe_track_iframe_app(socket, app_id) do
    if app_id in socket.assigns.opened_iframe_apps do
      socket
    else
      assign(socket, :opened_iframe_apps, socket.assigns.opened_iframe_apps ++ [app_id])
    end
  end

  # -- Private Helpers --

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

  defp handle_iframe_message(socket, app_id, %{"type" => "cyfr:request"} = msg) do
    app = Enum.find(socket.assigns.iframe_apps, &(&1.id == app_id))

    if app do
      case msg["action"] do
        "tool_call" ->
          handle_tool_call(socket, app_id, app, msg)

        "set_title" ->
          iframe_apps =
            Enum.map(socket.assigns.iframe_apps, fn a ->
              if a.id == app_id,
                do: Map.put(a, :title, msg["payload"]["title"] || a.title),
                else: a
            end)

          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}

          {:noreply,
           socket
           |> assign(:iframe_apps, iframe_apps)
           |> push_event("iframe_response:#{app_id}", response)}

        "close" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          socket = push_event(socket, "iframe_response:#{app_id}", response)

          opened = List.delete(socket.assigns.opened_iframe_apps, app_id)

          active =
            if socket.assigns.active_iframe_app == app_id do
              List.first(opened)
            else
              socket.assigns.active_iframe_app
            end

          {:noreply,
           socket
           |> assign(:opened_iframe_apps, opened)
           |> assign(:active_iframe_app, active)}

        "ready" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}

        "get_context" ->
          response = %{
            type: "cyfr:response",
            id: msg["id"],
            result: %{app_id: app.id, window_id: app_id}
          }

          {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}

        _ ->
          error_response = %{
            type: "cyfr:response",
            id: msg["id"],
            error: "unknown_action"
          }

          {:noreply, push_event(socket, "iframe_response:#{app_id}", error_response)}
      end
    else
      if msg["id"] do
        response = %{type: "cyfr:response", id: msg["id"], error: "window_not_found"}
        {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}
      else
        {:noreply, socket}
      end
    end
  end

  defp handle_iframe_message(socket, _app_id, _msg), do: {:noreply, socket}

  defp handle_tool_call(socket, app_id, app, msg) do
    tool = get_in(msg, ["payload", "tool"])
    args = get_in(msg, ["payload", "args"]) || %{}

    allowed = get_in(app, [:manifest, "setup", "policy", "allowed_tools"]) || []
    Logger.info("iframe tool_call: app=#{app.id} tool=#{tool}")

    if tool_allowed?(tool, allowed) do
      case call_tool(socket, tool, args) do
        {:ok, result} ->
          response = %{type: "cyfr:response", id: msg["id"], result: result}
          {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}

        {:error, reason} ->
          Logger.warning(
            "iframe tool_call failed: app=#{app.id} tool=#{tool} error=#{inspect(reason)}"
          )

          response = %{type: "cyfr:response", id: msg["id"], error: "tool_call_failed"}
          {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}
      end
    else
      Logger.warning("iframe tool_call denied: app=#{app.id} tool=#{tool}")

      response = %{
        type: "cyfr:response",
        id: msg["id"],
        error: "tool_not_allowed"
      }

      {:noreply, push_event(socket, "iframe_response:#{app_id}", response)}
    end
  end

  defp tool_allowed?(_tool, ["*"]), do: true

  defp tool_allowed?(tool, allowed) do
    normalized = String.replace(tool, "/", ".")
    Enum.any?(allowed, fn a -> a == tool || String.replace(a, "/", ".") == normalized end)
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[ShellLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="shell"
      class="relative w-screen h-screen overflow-hidden bg-gray-950 flex flex-col"
      phx-hook="ShellViewport"
    >
      <%!-- Sidebar + Content --%>
      <div class="flex flex-1 overflow-hidden">
        <%!-- Sidebar --%>
        <div class="w-52 bg-gray-900/60 border-r border-gray-700/50 flex flex-col shrink-0">
          <%!-- Desktop switcher --%>
          <div class="flex items-center gap-1 px-3 pt-3 pb-2">
            <button
              phx-click="switch_desktop"
              phx-value-desktop="system"
              class={[
                "flex-1 px-2 py-1.5 rounded-lg text-xs font-medium transition-colors text-center",
                if(@desktop == :system,
                  do: "bg-blue-600/20 text-blue-300",
                  else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-200"
                )
              ]}
            >
              System
            </button>
            <button
              phx-click="switch_desktop"
              phx-value-desktop="apps"
              class={[
                "flex-1 px-2 py-1.5 rounded-lg text-xs font-medium transition-colors text-center",
                if(@desktop == :apps,
                  do: "bg-blue-600/20 text-blue-300",
                  else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-200"
                )
              ]}
            >
              Apps
            </button>
          </div>
          <div class="mx-3 border-t border-gray-700/50" />
          <%!-- Nav list --%>
          <div class="flex-1 overflow-y-auto">
            <%= if @desktop == :system do %>
              <.system_sidebar
                categorized_native_apps={@categorized_native_apps}
                active_system_app={@active_system_app}
              />
            <% else %>
              <.apps_sidebar
                iframe_apps={@iframe_apps}
                active_iframe_app={@active_iframe_app}
              />
            <% end %>
          </div>
        </div>

        <%!-- Content panel --%>
        <div class="relative flex-1 overflow-hidden">
          <%!-- System apps --%>
          <%= for app_id <- @opened_system_apps do %>
            <% app_info = @native_apps[app_id] %>
            <div class={[
              "absolute inset-0 flex flex-col overflow-y-auto",
              if(@desktop != :system or app_id != @active_system_app, do: "hidden")
            ]}>
              {live_render(@socket, app_info.module,
                id: "system_#{app_id}",
                session: %{"shell" => true, "session_token" => @session_token}
              )}
            </div>
          <% end %>

          <%!-- iframe apps --%>
          <%= for app_id <- @opened_iframe_apps do %>
            <% app = Enum.find(@iframe_apps, &(&1.id == app_id)) %>
            <div
              :if={app}
              class={[
                "absolute inset-0 flex flex-col",
                if(@desktop != :apps or app_id != @active_iframe_app, do: "hidden")
              ]}
            >
              <iframe
                id={"iframe_#{app_id}"}
                src={app.url}
                sandbox="allow-scripts allow-same-origin"
                class="w-full h-full border-0"
                phx-hook="IframeBridge"
                data-window-id={app_id}
              />
            </div>
          <% end %>

          <%!-- Empty state for apps desktop --%>
          <div
            :if={@desktop == :apps and @active_iframe_app == nil}
            class="flex flex-col items-center justify-center h-full text-gray-500 gap-4"
          >
            <svg class="w-12 h-12 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="1.5"
                d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
              />
            </svg>
            <p class="text-sm">
              <%= if @iframe_apps == [], do: "No apps installed", else: "Select an app from the sidebar" %>
            </p>
          </div>
        </div>
      </div>

    </div>
    """
  end

  # -- Function Components --

  defp system_sidebar(assigns) do
    ~H"""
    <div class="px-3 py-2">
      <%= for {label, apps} <- @categorized_native_apps do %>
        <div class="mb-1">
          <h3 :if={label} class="text-[10px] font-semibold text-gray-600 uppercase tracking-wider mt-3 mb-1 px-2">
            {label}
          </h3>
          <nav class="flex flex-col gap-0.5">
            <%= for app <- apps do %>
              <button
                phx-click="select_system_app"
                phx-value-app={app.id}
                class={[
                  "flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left transition-colors w-full",
                  if(app.id == @active_system_app,
                    do: "bg-blue-600/20 text-blue-300",
                    else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-200"
                  )
                ]}
              >
                <.icon name={app.icon} class="h-4 w-4 shrink-0" />
                <span class="text-sm truncate">{app.title}</span>
              </button>
            <% end %>
          </nav>
        </div>
      <% end %>
    </div>
    """
  end

  defp apps_sidebar(assigns) do
    ~H"""
    <div class="px-3 py-3">
      <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2 px-2">
        Installed Apps
      </h2>
      <nav :if={@iframe_apps != []} class="flex flex-col gap-0.5">
        <%= for app <- @iframe_apps do %>
          <button
            phx-click="select_iframe_app"
            phx-value-app={app.id}
            class={[
              "flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left transition-colors w-full",
              if(app.id == @active_iframe_app,
                do: "bg-blue-600/20 text-blue-300",
                else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-200"
              )
            ]}
          >
            <.icon name={app.icon} class="h-4 w-4 shrink-0" />
            <span class="text-sm truncate">{app.title}</span>
          </button>
        <% end %>
      </nav>
      <p :if={@iframe_apps == []} class="text-sm text-gray-600 px-2">No apps installed</p>
    </div>
    """
  end

end
