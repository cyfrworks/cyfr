# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLive do
  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:requests", ctx))
    end

    if connected?(socket) and socket.assigns.context.platform_admin do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.platform_topic())
    end

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:active_nav, "settings")
      |> assign(:system_status, nil)
      |> assign(:log_stats, %{total: 0, errors: 0, avg_duration_ms: 0, error_rate: 0.0})
      |> assign(:door_entries, [])
      |> assign(:door_requests, [])
      |> assign(:door_value, "")
      |> assign(:door_note, "")
      |> assign(:mode, Prism.Labels.default(socket.assigns.context))
      |> assign(:loading, true)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      {:noreply,
       socket
       |> load_system_status()
       |> load_log_stats()
       |> load_door()
       |> load_prefs()
       |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("door_form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:door_value, Map.get(params, "value", socket.assigns.door_value))
     |> assign(:door_note, Map.get(params, "note", socket.assigns.door_note))}
  end

  def handle_event("door_allow", %{"value" => value} = params, socket) do
    door_call(socket, "door/allow", %{"value" => value, "note" => params["note"]}, "Allowed.")
  end

  def handle_event("door_deny", %{"value" => value} = params, socket) do
    door_call(socket, "door/deny", %{"value" => value, "note" => params["note"]}, "Denied.")
  end

  def handle_event("door_remove", %{"id" => id}, socket) do
    door_call(socket, "door/remove", %{"id" => id}, "Entry removed.")
  end

  def handle_event("door_resolve", %{"id" => id, "decision" => decision}, socket) do
    door_call(socket, "door/resolve", %{"id" => id, "decision" => decision}, "Request resolved.")
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["lite", "dev"] do
    case Sanctum.Tenancy.Users.get(socket.assigns.context.user_id) do
      {:ok, user} ->
        {:ok, _} = Sanctum.Tenancy.Users.put_prefs(user, %{"mode" => mode})

        {:noreply,
         socket
         |> assign(:mode, mode)
         |> assign(:ui_mode, mode)
         |> put_flash(:info, "Mode saved.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not save the preference.")}
    end
  end

  @impl true
  def handle_info({:request, _metadata, _measurements}, socket) do
    {:noreply, load_log_stats(socket)}
  end

  def handle_info({:notify, :platform, :allowlist_request, _payload}, socket) do
    {:noreply, load_door(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[SettingsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_system_status(socket) do
    case call_tool(socket, "system/status", %{}) do
      {:ok, status} -> assign(socket, :system_status, status)
      {:error, _} -> assign(socket, :system_status, %{})
    end
  end

  defp load_log_stats(socket) do
    case call_tool(socket, "mcp_log", %{"action" => "stats"}) do
      {:ok, stats} ->
        assign(socket, :log_stats, %{
          total: stats[:total] || stats["total"] || 0,
          errors: stats[:errors] || stats["errors"] || 0,
          avg_duration_ms: stats[:avg_duration_ms] || stats["avg_duration_ms"] || 0,
          error_rate: stats[:error_rate] || stats["error_rate"] || 0.0
        })

      _ ->
        socket
    end
  end

  defp door_call(socket, tool, args, ok_message) do
    case call_tool(socket, tool, args) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:door_value, "")
         |> assign(:door_note, "")
         |> load_door()
         |> put_flash(:info, ok_message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Door: #{inspect(reason)}")}
    end
  end

  # The door is the platform admin's; everyone else sees no section.
  defp load_door(%{assigns: %{context: %{platform_admin: true}}} = socket) do
    entries =
      case call_tool(socket, "door/list", %{}) do
        {:ok, %{entries: entries}} -> Enum.reject(entries, &(&1.status == "requested"))
        _ -> []
      end

    requests =
      case call_tool(socket, "door/requests", %{}) do
        {:ok, %{requests: requests}} -> requests
        _ -> []
      end

    socket |> assign(:door_entries, entries) |> assign(:door_requests, requests)
  end

  defp load_door(socket), do: socket

  defp load_prefs(socket) do
    ctx = socket.assigns.context

    case Sanctum.Tenancy.Users.get(ctx.user_id) do
      {:ok, user} ->
        assign(socket, :mode, Prism.Labels.mode(Sanctum.Tenancy.Users.prefs(user)["mode"], ctx))

      _ ->
        socket
    end
  end

  defp status_field(nil, _key), do: nil
  defp status_field(status, key), do: status[key] || status[to_string(key)]

  defp services_map(nil), do: %{}
  defp services_map(services) when is_map(services), do: services
  defp services_map(_), do: %{}

  defp service_dot("ok"), do: "bg-green-400"
  defp service_dot("error"), do: "bg-red-400"
  defp service_dot("degraded"), do: "bg-yellow-400"
  defp service_dot(_), do: "bg-gray-400"

  defp format_uptime(nil), do: "-"

  defp format_uptime(seconds) when is_number(seconds) do
    cond do
      seconds >= 86400 ->
        days = div(trunc(seconds), 86400)
        hours = div(rem(trunc(seconds), 86400), 3600)
        "#{days}d #{hours}h"

      seconds >= 3600 ->
        hours = div(trunc(seconds), 3600)
        mins = div(rem(trunc(seconds), 3600), 60)
        "#{hours}h #{mins}m"

      seconds >= 60 ->
        mins = div(trunc(seconds), 60)
        secs = rem(trunc(seconds), 60)
        "#{mins}m #{secs}s"

      true ->
        "#{trunc(seconds)}s"
    end
  end

  defp format_uptime(_), do: "-"

  @impl true
  def render(assigns) do
    services = services_map(status_field(assigns.system_status, :services))
    mcp = status_field(assigns.system_status, :mcp) || %{}

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:mcp, mcp)

    ~H"""
    <div class="space-y-6">
      <.page_header title="Settings">
        <:actions>
          <a
            href={~p"/auth/logout"}
            class="inline-flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium bg-gray-700 text-gray-200 hover:bg-gray-600 transition-colors"
          >
            <.icon name="logout" class="h-4 w-4" /> Sign Out
          </a>
        </:actions>
      </.page_header>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <!-- System Status -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">System Status</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Version</dt>
              <dd class="text-2xl font-bold text-white mt-1">
                {status_field(@system_status, :version) || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Uptime</dt>
              <dd class="text-2xl font-bold text-white mt-1">
                {format_uptime(status_field(@system_status, :uptime_seconds))}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">MCP Protocol</dt>
              <dd class="text-sm text-white mt-1 font-mono">
                {status_field(@mcp, :protocol_version) || "-"}
              </dd>
              <dd class="text-xs text-gray-500 mt-0.5">
                {status_field(@mcp, :tools_count) || 0} tools, {status_field(@mcp, :resources_count) ||
                  0} resources
              </dd>
            </div>
          </div>
        </.card>
        
    <!-- Services -->
        <.card :if={@services != %{}}>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Services</h3>
          <div class="flex flex-wrap gap-x-4 gap-y-2">
            <%= for {name, status} <- Enum.sort(@services) do %>
              <span class="flex items-center gap-1.5">
                <span class={["h-2 w-2 rounded-full", service_dot(to_string(status))]} />
                <span class="text-sm text-gray-300">{name}</span>
              </span>
            <% end %>
          </div>
        </.card>
        
    <!-- Request Metrics -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Request Metrics (1h)</h3>
          <div class="grid grid-cols-3 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Total Requests</dt>
              <dd class="text-2xl font-bold text-white mt-1">{@log_stats.total}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Error Rate</dt>
              <dd class={"text-2xl font-bold mt-1 #{if @log_stats.error_rate > 0, do: "text-red-400", else: "text-green-400"}"}>
                {@log_stats.error_rate}%
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Avg Duration</dt>
              <dd class="text-2xl font-bold text-white mt-1">{@log_stats.avg_duration_ms}ms</dd>
            </div>
          </div>
        </.card>
        
    <!-- The door: who may sign in (platform admins) -->
        <.card :if={@context.platform_admin}>
          <h3 class="text-sm font-medium text-gray-400 mb-1">Server allowlist — the door</h3>
          <p class="text-xs text-gray-500 mb-4">
            Who may sign in here. An email, an IdP subject, or <code>*</code>
            for anyone the provider authenticates. A deny is sticky and ejects the person.
          </p>

          <div :if={@door_requests != []} class="mb-4">
            <h4 class="text-xs text-gray-500 uppercase mb-2">Requests</h4>
            <.table id="door-requests" rows={@door_requests}>
              <:col :let={r} label="Email">{r.value}</:col>
              <:col :let={r} label="Asked by">{r.requested_by || "-"}</:col>
              <:col :let={r} label="Actions">
                <div class="flex gap-2">
                  <.button
                    variant="ghost"
                    phx-click="door_resolve"
                    phx-value-id={r.id}
                    phx-value-decision="allow"
                  >
                    Allow
                  </.button>
                  <.button
                    variant="ghost"
                    phx-click="door_resolve"
                    phx-value-id={r.id}
                    phx-value-decision="reject"
                  >
                    Reject
                  </.button>
                </div>
              </:col>
            </.table>
          </div>

          <div :if={@door_entries == []} class="py-4">
            <.empty_state message="Only the platform admins can sign in — the list is empty" />
          </div>
          <.table :if={@door_entries != []} id="door-entries" rows={@door_entries}>
            <:col :let={e} label="Entry">{e.value}</:col>
            <:col :let={e} label="Kind">{e.kind}</:col>
            <:col :let={e} label="Effect">
              <.badge color={if e.effect == "allow", do: "green", else: "red"}>{e.effect}</.badge>
            </:col>
            <:col :let={e} label="Note">{e.note || "-"}</:col>
            <:col :let={e} label="Actions">
              <.button variant="ghost" phx-click="door_remove" phx-value-id={e.id}>
                Remove
              </.button>
            </:col>
          </.table>

          <form phx-change="door_form_changed" class="mt-4 space-y-2">
            <div class="flex gap-2 items-end">
              <div class="flex-1">
                <.input name="value" value={@door_value} required placeholder="email, subject, or *" />
              </div>
              <div class="flex-1">
                <.input name="note" value={@door_note} placeholder="note (optional)" />
              </div>
              <.button
                type="button"
                phx-click="door_allow"
                phx-value-value={@door_value}
                phx-value-note={@door_note}
              >
                Allow
              </.button>
              <.button
                type="button"
                variant="ghost"
                phx-click="door_deny"
                phx-value-value={@door_value}
                phx-value-note={@door_note}
                data-confirm="Deny this person? Their sessions and keys are revoked."
              >
                Deny
              </.button>
            </div>
          </form>
        </.card>
        
    <!-- Preferences -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Preferences</h3>
          <div class="flex items-center gap-3">
            <span class="text-sm text-gray-300">Mode</span>
            <.button
              :for={m <- ["lite", "dev"]}
              variant={if @mode == m, do: "primary", else: "ghost"}
              phx-click="set_mode"
              phx-value-mode={m}
            >
              {m}
            </.button>
          </div>
        </.card>
        
    <!-- User Profile -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">User Profile</h3>
          <dl class="grid grid-cols-2 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Namespace</dt>
              <dd class="text-sm text-white mt-1">
                {assigns[:personal_namespace_slug] || "(not claimed)"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Email</dt>
              <dd class="text-sm text-white mt-1">{@current_user.email || "-"}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Provider</dt>
              <dd class="text-sm text-white mt-1">{@current_user.provider}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Auth Method</dt>
              <dd class="text-sm text-white mt-1">{@context.auth_method || "-"}</dd>
            </div>
            <div class="col-span-2">
              <dt class="text-xs text-gray-500 uppercase">User ID</dt>
              <dd class="text-xs text-gray-400 mt-1 font-mono break-all">{@current_user.user_id}</dd>
            </div>
          </dl>
        </.card>
      </div>
    </div>
    """
  end
end
