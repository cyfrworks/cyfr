# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLive do
  @moduledoc """
  Live "vital signs" topbar — nested LiveView mounted via `live_render` in
  the app layout, persistent across page navigation.

  Seven indicators, each a small icon/badge with click-to-expand popover:

  | Indicator   | Source                 | Subscribes              |
  |-------------|------------------------|-------------------------|
  | Health      | system/status          | (loaded on mount)       |
  | Activity    | mcp_log/list           | prism:requests + tinctures + schedules |
  | Executions  | execution/list         | prism:executions        |
  | Rate        | mcp_log/stats          | prism:requests          |
  | Schedules   | schedule/list          | prism:schedules         |
  | Builds      | telemetry-only         | prism:builds            |
  | Tinctures   | telemetry-only         | prism:tinctures         |

  Builds and Tinctures hide entirely when there's nothing to show, so the
  bar stays compact in normal operation.
  """

  use PrismWeb, :live_view

  require Logger

  @recent_requests_limit 5
  @recent_tincture_limit 5
  @max_in_flight_builds 5

  @impl true
  def mount(_params, session, socket) do
    token = session["sanctum_session_token"]

    socket =
      case PrismWeb.AuthHelpers.authenticate_session(token, session["athanor_id"]) do
        {:ok, ctx} ->
          if connected?(socket) do
            for topic <- [
                  "prism:requests",
                  "prism:executions",
                  "prism:schedules",
                  "prism:builds",
                  "prism:tinctures"
                ] do
              Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic(topic, ctx))
            end

            # The person's own memberships change what the switcher lists.
            Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Tenancy.Members.topic(ctx.user_id))
          end

          slug = PrismWeb.AuthHelpers.personal_namespace_slug(ctx.user_id)

          socket
          |> assign(:context, ctx)
          |> assign(:current_user, ctx)
          |> assign(:personal_namespace_slug, slug)
          |> assign(:authenticated, true)
          |> assign(:session_token, token)
          |> assign(:athanor_route, PrismWeb.Focus.route_of(ctx))
          |> assign(:badges, %{})
          |> load_athanors(ctx)

        _ ->
          socket
          |> assign(:current_user, nil)
          |> assign(:personal_namespace_slug, nil)
          |> assign(:authenticated, false)
          |> assign(:session_token, nil)
          |> assign(:athanor_route, nil)
          |> assign(:athanors, [])
          |> assign(:badges, %{})
      end

    {:ok,
     socket
     |> assign(:open_popover, nil)
     |> assign(:system_status, nil)
     |> assign(:running_requests, [])
     |> assign(:running_executions, [])
     |> assign(:log_stats, %{total: 0, errors: 0, avg_duration_ms: 0, error_rate: 0.0})
     |> assign(:upcoming_schedules, [])
     |> assign(:in_flight_builds, [])
     |> assign(:recent_tinctures, [])
     |> load_initial_state(), layout: false}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("toggle_popover", %{"name" => name}, socket) do
    next = if socket.assigns.open_popover == name, do: nil, else: name
    {:noreply, assign(socket, :open_popover, next)}
  end

  def handle_event("close_popover", _params, socket) do
    {:noreply, assign(socket, :open_popover, nil)}
  end

  # The one create the chat list offers: a group, born with its creator as
  # the only member. The new athanor opens; the topbar remounts with it.
  def handle_event("create_group", %{"name" => name}, socket) do
    case call_tool(socket, "athanor/create", %{"name" => String.trim(name)}) do
      {:ok, %{route: route}} when is_binary(route) ->
        {:noreply, push_navigate(socket, to: PrismWeb.Focus.path(route, ""))}

      {:ok, _} ->
        {:noreply, socket |> assign(:open_popover, nil) |> load_athanors(socket.assigns.context)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create the group: #{inspect(reason)}")}
    end
  end

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info({:request, _meta, _meas}, socket) do
    {:noreply, socket |> load_running_requests() |> load_log_stats()}
  end

  def handle_info({:tincture_invoke_started, metadata, _meas}, socket) do
    {:noreply, socket |> add_recent_tincture(metadata, :started) |> load_running_requests()}
  end

  def handle_info({:tincture_invoke_stopped, metadata, _meas}, socket) do
    {:noreply, socket |> add_recent_tincture(metadata, :stopped) |> load_running_requests()}
  end

  def handle_info({:execution_started, _meta, _meas}, socket) do
    {:noreply, load_running_executions(socket)}
  end

  def handle_info({:execution_completed, _meta, _meas}, socket) do
    {:noreply, load_running_executions(socket)}
  end

  def handle_info({:execution_failed, _meta, _meas}, socket) do
    {:noreply, load_running_executions(socket)}
  end

  def handle_info({:schedule_fired, _meta, _meas}, socket) do
    {:noreply, socket |> load_upcoming_schedules() |> load_running_requests()}
  end

  def handle_info({:build_started, metadata, _meas}, socket) do
    {:noreply, track_build_started(socket, metadata)}
  end

  def handle_info({:build_progress, _meta, _meas}, socket), do: {:noreply, socket}

  def handle_info({:build_stopped, metadata, _meas}, socket) do
    {:noreply, track_build_stopped(socket, metadata)}
  end

  # The tray: one fan-in topic per athanor the person belongs to. Something
  # happening in an athanor that is not in focus becomes a badge on its row;
  # the focused one shows its own live indicators. Only what wants a
  # person's attention badges: a card settled by someone else does not,
  # and an athanor renamed or reconfigured just redraws the list.
  def handle_info({:notify, _athanor_id, :approval_resolved, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    {:noreply, load_athanors(socket, socket.assigns.context)}
  end

  def handle_info({:notify, athanor_id, _kind, _payload}, socket) do
    if athanor_id == socket.assigns.context.athanor_id do
      {:noreply, socket}
    else
      {:noreply, update(socket, :badges, &Map.update(&1, athanor_id, 1, fn n -> n + 1 end))}
    end
  end

  def handle_info({:membership_changed, _change}, socket) do
    {:noreply, load_athanors(socket, socket.assigns.context)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[TopbarLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Loaders
  # ============================================================================

  defp load_initial_state(socket) do
    if socket.assigns[:authenticated] do
      socket
      |> load_system_status()
      |> load_running_requests()
      |> load_running_executions()
      |> load_log_stats()
      |> load_upcoming_schedules()
    else
      socket
    end
  end

  defp load_system_status(socket) do
    case mcp_call(socket, "system/status", %{}) do
      {:ok, status} -> assign(socket, :system_status, status)
      _ -> assign(socket, :system_status, %{})
    end
  end

  defp load_running_requests(socket) do
    case mcp_call(socket, "mcp_log", %{
           "action" => "list",
           "limit" => @recent_requests_limit,
           "status" => "pending"
         }) do
      {:ok, %{logs: logs}} when is_list(logs) -> assign(socket, :running_requests, logs)
      _ -> assign(socket, :running_requests, [])
    end
  end

  defp load_running_executions(socket) do
    case mcp_call(socket, "execution", %{
           "action" => "list",
           "status" => "running",
           "limit" => 20
         }) do
      {:ok, %{executions: list}} when is_list(list) -> assign(socket, :running_executions, list)
      _ -> assign(socket, :running_executions, [])
    end
  end

  defp load_log_stats(socket) do
    case mcp_call(socket, "mcp_log", %{"action" => "stats"}) do
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

  defp load_upcoming_schedules(socket) do
    case mcp_call(socket, "schedule", %{"action" => "list"}) do
      {:ok, %{schedules: list}} when is_list(list) ->
        upcoming =
          list
          |> Enum.filter(&schedule_active?/1)
          |> Enum.sort_by(&next_run_sort_key/1)
          |> Enum.take(3)

        assign(socket, :upcoming_schedules, upcoming)

      _ ->
        assign(socket, :upcoming_schedules, [])
    end
  end

  defp mcp_call(socket, tool_name, args) do
    case socket.assigns[:context] do
      %Sanctum.Context{} = ctx ->
        {name, merged} =
          case String.split(tool_name, "/", parts: 2) do
            [n, action] -> {n, Map.put(args, "action", action)}
            [n] -> {n, args}
          end

        Emissary.MCP.ToolRegistry.call_external(name, ctx, merged)

      _ ->
        {:error, :no_context}
    end
  end

  # ============================================================================
  # In-memory feeds
  # ============================================================================

  defp add_recent_tincture(socket, metadata, lifecycle) do
    entry = %{
      request_id: metadata[:request_id],
      tincture_ref: metadata[:tincture_ref],
      reference: metadata[:reference],
      status: lifecycle_status(lifecycle, metadata),
      ts: System.system_time(:millisecond)
    }

    list =
      [entry | socket.assigns.recent_tinctures]
      |> Enum.uniq_by(& &1.request_id)
      |> Enum.take(@recent_tincture_limit)

    assign(socket, :recent_tinctures, list)
  end

  defp lifecycle_status(:started, _meta), do: "pending"
  defp lifecycle_status(:stopped, %{status: :ok}), do: "success"
  defp lifecycle_status(:stopped, %{status: :error}), do: "error"
  defp lifecycle_status(:stopped, _), do: "success"

  defp track_build_started(socket, metadata) do
    entry = %{
      build_id: metadata[:build_id],
      reference: metadata[:reference],
      ts: System.system_time(:millisecond)
    }

    list =
      [entry | socket.assigns.in_flight_builds]
      |> Enum.uniq_by(& &1.build_id)
      |> Enum.take(@max_in_flight_builds)

    assign(socket, :in_flight_builds, list)
  end

  defp track_build_stopped(socket, metadata) do
    list =
      Enum.reject(socket.assigns.in_flight_builds, fn b -> b.build_id == metadata[:build_id] end)

    assign(socket, :in_flight_builds, list)
  end

  # ============================================================================
  # Display helpers
  # ============================================================================

  defp f(m, k), do: m[k] || m[to_string(k)]

  defp services_map(nil), do: %{}
  defp services_map(s) when is_map(s), do: s
  defp services_map(_), do: %{}

  defp status_field(nil, _key), do: nil
  defp status_field(s, k), do: s[k] || s[to_string(k)]

  defp schedule_active?(s) do
    enabled = s[:enabled] || s["enabled"]
    is_nil(enabled) or enabled == true
  end

  defp next_run_sort_key(s) do
    next = s[:next_run_at] || s["next_run_at"]

    cond do
      is_binary(next) -> next
      is_nil(next) -> "9999"
      true -> to_string(next)
    end
  end

  # Single dot color summarising overall service health: red if any down,
  # amber if any degraded, green if all OK, gray if unknown.
  defp health_dot_class(services) when is_map(services) and map_size(services) > 0 do
    statuses = services |> Map.values() |> Enum.map(&to_string/1)

    cond do
      Enum.any?(statuses, &(&1 in ~w(error down failed))) -> "bg-red-400"
      Enum.any?(statuses, &(&1 in ~w(degraded warn warning))) -> "bg-amber-400"
      Enum.all?(statuses, &(&1 in ~w(ok healthy up))) -> "bg-green-400"
      true -> "bg-gray-400"
    end
  end

  defp health_dot_class(_), do: "bg-gray-400"

  defp service_dot(status) do
    case to_string(status) do
      s when s in ~w(ok healthy up) -> "bg-green-400"
      s when s in ~w(error down failed) -> "bg-red-400"
      s when s in ~w(degraded warn warning) -> "bg-amber-400"
      _ -> "bg-gray-400"
    end
  end

  defp short(nil), do: ""
  defp short(s) when is_binary(s) and byte_size(s) > 24, do: String.slice(s, 0, 24) <> "…"
  defp short(s), do: to_string(s)

  defp source_class("tincture"), do: "bg-pink-900/30 text-pink-300"
  defp source_class("schedule"), do: "bg-amber-900/30 text-amber-300"
  defp source_class(_), do: "bg-blue-900/30 text-blue-300"

  defp source_label("tincture"), do: "Tincture"
  defp source_label("schedule"), do: "Cron"
  defp source_label(_), do: "MCP"

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    services = services_map(status_field(assigns.system_status, :services))

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:running_requests_count, length(assigns.running_requests))
      |> assign(:running_executions_count, length(assigns.running_executions))
      |> assign(:next_schedule, List.first(assigns.upcoming_schedules))
      |> assign(:builds_count, length(assigns.in_flight_builds))
      |> assign(:tincture_count, length(assigns.recent_tinctures))

    ~H"""
    <div class="flex h-12 items-center justify-between gap-2 border-b border-gray-800 bg-gray-900 px-3 text-xs">
      <!-- Brand + the athanor in focus (the switcher: You, then your groups) -->
      <div class="flex items-center gap-2 lg:w-[15rem] lg:pl-1">
        <.link navigate="/" class="flex items-center gap-2">
          <img src={~p"/images/logo.jpg"} alt="CYFR" class="h-7 w-7 rounded-md" />
          <span class="text-lg font-bold text-white tracking-tight">CYFR</span>
        </.link>
        <div :if={@authenticated} class="relative">
          <button
            type="button"
            phx-click="toggle_popover"
            phx-value-name="athanors"
            class={[
              "inline-flex items-center gap-1.5 rounded-md px-2 py-1 transition-colors max-w-[10rem]",
              if(@open_popover == "athanors",
                do: "bg-gray-800 text-gray-200",
                else: "text-gray-300 hover:bg-gray-800/60"
              )
            ]}
          >
            <span class="truncate text-xs font-medium">{focused_name(@athanors, @context)}</span>
            <span
              :if={badge_total(@badges, @context) > 0}
              class="h-2 w-2 rounded-full bg-blue-400 shrink-0"
            />
            <span class="text-gray-500">▾</span>
          </button>
          <div
            :if={@open_popover == "athanors"}
            phx-click-away="close_popover"
            class="absolute left-0 top-full mt-2 w-64 rounded-lg border border-gray-700 bg-gray-900 shadow-xl p-2 z-40"
          >
            <ul :if={length(@athanors) > 1} class="space-y-0.5 text-sm">
              <li :for={a <- @athanors}>
                <.link
                  navigate={PrismWeb.Focus.path(a, "")}
                  class={[
                    "flex items-center justify-between rounded-md px-2 py-1.5",
                    if(a.id == @context.athanor_id,
                      do: "bg-gray-800 text-white",
                      else: "text-gray-300 hover:bg-gray-800/60"
                    )
                  ]}
                >
                  <span class="truncate">
                    {if a.kind == "person", do: "You", else: a.name}
                    <span class="text-xs text-gray-500 ml-1">
                      {Sanctum.Tenancy.Athanors.route_slug(a)}
                    </span>
                  </span>
                  <span
                    :if={Map.get(@badges, a.id, 0) > 0}
                    class="ml-2 rounded-full bg-blue-500/80 px-1.5 text-[10px] text-white"
                  >
                    {Map.get(@badges, a.id)}
                  </span>
                </.link>
              </li>
            </ul>
            <form
              phx-submit="create_group"
              class={["flex items-center gap-1 px-1", if(length(@athanors) > 1, do: "mt-2 pt-2 border-t border-gray-800", else: "")]}
            >
              <input
                type="text"
                name="name"
                required
                minlength="1"
                maxlength="80"
                placeholder="New group…"
                autocomplete="off"
                class="flex-1 min-w-0 rounded-md border border-gray-700 bg-gray-950 px-2 py-1 text-xs text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
              />
              <button
                type="submit"
                class="rounded-md bg-gray-800 px-2 py-1 text-[11px] text-gray-200 hover:bg-gray-700"
              >
                Create
              </button>
            </form>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <!-- Builds (only when active) -->
        <.indicator
          :if={@builds_count > 0}
          name="builds"
          open={@open_popover == "builds"}
          label={"#{@builds_count}"}
          icon="wrench"
          dot_class="bg-amber-400 animate-pulse"
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">Builds in flight</h4>
            <ul class="space-y-1 text-sm">
              <%= for b <- @in_flight_builds do %>
                <li class="flex items-center gap-2">
                  <span class="h-1.5 w-1.5 rounded-full bg-amber-400 animate-pulse shrink-0" />
                  <span class="text-gray-300 font-mono text-xs truncate">
                    {b.reference || b.build_id}
                  </span>
                </li>
              <% end %>
            </ul>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/builds")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              View all builds →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Tinctures (only when recent activity) -->
        <.indicator
          :if={@tincture_count > 0}
          name="tinctures"
          open={@open_popover == "tinctures"}
          label={"#{@tincture_count}"}
          icon="palette"
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">Recent tincture invokes</h4>
            <ul class="space-y-1 text-sm">
              <%= for t <- @recent_tinctures do %>
                <li class="flex items-center gap-2">
                  <.status_indicator status={t.status} />
                  <span class="text-gray-300 font-mono text-xs truncate">
                    {t.tincture_ref || t.reference || t.request_id}
                  </span>
                </li>
              <% end %>
            </ul>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/tinctures")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              Open Tinctures →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Schedules -->
        <.indicator
          :if={@next_schedule}
          name="schedules"
          open={@open_popover == "schedules"}
          label={f(@next_schedule, :name) || short(f(@next_schedule, :id))}
          icon="clock"
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">Upcoming schedules</h4>
            <ul class="space-y-1 text-sm">
              <%= for s <- @upcoming_schedules do %>
                <li class="flex items-center justify-between gap-2">
                  <span class="text-gray-300 truncate">{f(s, :name) || f(s, :id)}</span>
                  <span class="text-xs text-gray-500 whitespace-nowrap">
                    {relative_time(f(s, :next_run_at))}
                  </span>
                </li>
              <% end %>
            </ul>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/schedules")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              All schedules →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Rate -->
        <.indicator
          name="rate"
          open={@open_popover == "rate"}
          label={"#{@log_stats.total}/h"}
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">Request rate (last 1h)</h4>
            <dl class="grid grid-cols-3 gap-3 text-sm">
              <div>
                <dt class="text-xs text-gray-500 uppercase">Total</dt>
                <dd class="text-white font-medium">{@log_stats.total}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Errors</dt>
                <dd class={[
                  "font-medium",
                  if(@log_stats.error_rate > 0, do: "text-red-400", else: "text-green-400")
                ]}>
                  {@log_stats.error_rate}%
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Avg ms</dt>
                <dd class="text-white font-medium">{@log_stats.avg_duration_ms}</dd>
              </div>
            </dl>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/activities")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              View activity →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Executions -->
        <.indicator
          name="executions"
          open={@open_popover == "executions"}
          label={"#{@running_executions_count}"}
          icon="cube"
          dot_class={
            if @running_executions_count > 0, do: "bg-green-400 animate-pulse", else: "bg-gray-600"
          }
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">
              Running executions ({@running_executions_count})
            </h4>
            <.live_empty :if={@running_executions == []} message="No executions running." />
            <ul :if={@running_executions != []} class="space-y-1 text-sm">
              <%= for exec <- Enum.take(@running_executions, 8) do %>
                <li class="flex items-center gap-2">
                  <.status_indicator status={to_string(f(exec, :status) || "running")} />
                  <span class="text-gray-300 font-mono text-xs truncate flex-1">
                    {format_ref(f(exec, :reference))}
                  </span>
                </li>
              <% end %>
            </ul>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/executions?status=running")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              View all executions →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Activity -->
        <.indicator
          name="activity"
          open={@open_popover == "activity"}
          label={"#{@running_requests_count}"}
          icon="play"
          dot_class={
            if @running_requests_count > 0, do: "bg-green-400 animate-pulse", else: "bg-gray-600"
          }
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">
              In-flight requests ({@running_requests_count})
            </h4>
            <.live_empty :if={@running_requests == []} message="No requests in flight." />
            <ul :if={@running_requests != []} class="space-y-1 text-sm">
              <%= for log <- @running_requests do %>
                <li class="flex items-center gap-2">
                  <span class={[
                    "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0",
                    source_class(f(log, :tool))
                  ]}>
                    {source_label(f(log, :tool))}
                  </span>
                  <span class="text-gray-300 font-mono text-xs truncate flex-1">
                    {f(log, :tool) || "?"} / {f(log, :action) || "?"}
                  </span>
                </li>
              <% end %>
            </ul>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/activities?status=pending")}
              class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
            >
              View activity →
            </.link>
          </:popover>
        </.indicator>
        
    <!-- Health -->
        <.indicator
          name="health"
          open={@open_popover == "health"}
          label={status_field(@system_status, :version) || "—"}
          dot_class={health_dot_class(@services)}
        >
          <:popover>
            <h4 class="text-xs font-medium text-gray-400 mb-2">Service health</h4>
            <.live_empty :if={@services == %{}} message="No service data." />
            <ul :if={@services != %{}} class="space-y-1 text-sm">
              <%= for {name, status} <- Enum.sort(@services) do %>
                <li class="flex items-center justify-between gap-3">
                  <div class="flex items-center gap-2">
                    <span class={["h-2 w-2 rounded-full", service_dot(status)]} />
                    <span class="text-gray-300">{name}</span>
                  </div>
                  <span class="text-xs text-gray-500 font-mono">{status}</span>
                </li>
              <% end %>
            </ul>
            <div class="mt-2 pt-2 border-t border-gray-800 text-xs text-gray-500 space-y-0.5">
              <div :if={status_field(@system_status, :version)}>
                version:
                <span class="text-gray-300 font-mono">{status_field(@system_status, :version)}</span>
              </div>
            </div>
          </:popover>
        </.indicator>
        
    <!-- User -->
        <.indicator
          :if={@current_user}
          name="user"
          open={@open_popover == "user"}
          label={@personal_namespace_slug || @current_user.email || @current_user.user_id}
          icon="user"
        >
          <:popover>
            <dl class="space-y-2 text-sm">
              <div :if={@personal_namespace_slug}>
                <dt class="text-xs text-gray-500 uppercase">Namespace</dt>
                <dd class="text-white font-mono text-xs truncate">{@personal_namespace_slug}</dd>
              </div>
              <div :if={@current_user.email}>
                <dt class="text-xs text-gray-500 uppercase">Email</dt>
                <dd class="text-white text-xs truncate">{@current_user.email}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Provider</dt>
                <dd class="text-white text-xs">{@current_user.provider}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">User ID</dt>
                <dd class="text-gray-400 font-mono text-[11px] break-all">{@current_user.user_id}</dd>
              </div>
            </dl>
            <a
              href={~p"/auth/logout"}
              class="mt-3 flex items-center justify-center gap-2 rounded-md border border-gray-700 px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800 hover:text-white transition-colors"
            >
              <.icon name="logout" class="h-3.5 w-3.5" /> Sign out
            </a>
          </:popover>
        </.indicator>
      </div>
    </div>
    """
  end

  # The athanors the person may work in — their own first, then their
  # groups — each subscribed on its notify topic for the tray badges.
  defp load_athanors(socket, ctx) do
    athanors = Sanctum.Tenancy.list_athanors(ctx)

    if connected?(socket) do
      for a <- athanors do
        Phoenix.PubSub.unsubscribe(Emissary.PubSub, Sanctum.Notify.topic(a.id))
        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(a.id))
      end
    end

    assign(socket, :athanors, athanors)
  end

  defp focused_name(athanors, ctx) do
    case Enum.find(athanors, &(&1.id == ctx.athanor_id)) do
      %{kind: "person"} -> "You"
      %{name: name} -> name
      nil -> "Athanor"
    end
  end

  defp badge_total(badges, ctx) do
    badges |> Map.delete(ctx.athanor_id) |> Map.values() |> Enum.sum()
  end

  # ----------------------------------------------------------------------------
  # Indicator function component — button + anchored popover.
  # ----------------------------------------------------------------------------

  attr :name, :string, required: true
  attr :open, :boolean, required: true
  attr :label, :string, default: nil
  attr :icon, :string, default: nil
  attr :dot_class, :string, default: nil
  slot :popover, required: true

  defp indicator(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_popover"
        phx-value-name={@name}
        class={[
          "inline-flex items-center gap-1.5 rounded-md px-2 py-1 transition-colors",
          if(@open,
            do: "bg-gray-800 text-gray-200",
            else: "text-gray-400 hover:bg-gray-800/60 hover:text-gray-300"
          )
        ]}
      >
        <span :if={@dot_class} class={["h-2 w-2 rounded-full", @dot_class]} />
        <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5" />
        <span :if={@label} class="text-xs font-medium">{@label}</span>
      </button>

      <div
        :if={@open}
        phx-click-away="close_popover"
        class="absolute right-0 top-full mt-2 w-72 rounded-lg border border-gray-700 bg-gray-900 shadow-xl p-3 z-40"
      >
        {render_slot(@popover)}
      </div>
    </div>
    """
  end
end
