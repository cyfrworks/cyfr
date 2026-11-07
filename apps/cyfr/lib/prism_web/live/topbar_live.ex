# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLive do
  @moduledoc """
  The chrome — a nested LiveView mounted via `live_render` in the app
  layout, remounted with every page: the brand, the link to the person's
  AQUA, the mode switch, the drawer button, a search icon for the palette, the person, how many files
  people have offered the person and wait for their answer (`file/offers`,
  read again whenever their own topic, `Cyfr.Bus.file_offers/1`, says one
  moved), and — for a platform admin — how many door requests wait.

  In `dev` it also carries the live indicators, each a small icon/badge
  with a click-to-expand popover:

  | Indicator   | Source                 | Subscribes              |
  |-------------|------------------------|-------------------------|
  | Health      | system/status          | (loaded on mount)       |
  | Activity    | mcp_log/list           | bus:requests + tinctures + schedule_runs + feed_runs |
  | Executions  | execution/list         | bus:executions        |
  | Rate        | mcp_log/stats          | bus:requests          |
  | Schedules   | schedule/list          | bus:schedule_runs     |
  | Builds      | telemetry-only         | bus:builds            |
  | Tinctures   | telemetry-only         | bus:tinctures         |
  | User        | the session            |                         |

  Builds and Tinctures hide entirely when there's nothing to show, so the
  bar stays compact in normal operation. `lite` shows none of them: the
  chat is the page.

  ## The mode switch

  Dashboard | Canvas (`#mode-switch`), in every posture: the page this bar
  sits on is the Canvas mode when it is the shell, the Dashboard
  otherwise (the layout says which, `surface`). Each half is a link: the
  Canvas to `/a/<athanor>/canvas`, the Dashboard to the Dashboard page the
  person last had open in this browser session, or the chat. Ctrl+Alt+`
  (Control and Option on a Mac) follows the other half, as a click would
  (the `ModeSwitch` hook); the shell's document alone hears it, so no
  app's frame sees it, and nothing else in the shell binds it. A switch is
  a page navigation. The connected mount remembers the mode and the
  Dashboard page per browser session (`PrismWeb.Surface`). The Canvas mode
  draws no drawer, so the drawer button shows in the Dashboard alone; in
  the hand the drawer is the Dashboard's page list.
  """

  use PrismWeb, :live_view

  alias Cyfr.Bus
  alias Cyfr.Bus.Notify

  @recent_requests_limit 5
  @recent_tincture_limit 5
  @max_in_flight_builds 5

  # The indicator refresh window and drain order; see `refresh/2`.
  @refresh_window_ms 250
  @refresh_order [:requests, :executions, :log_stats, :schedules]

  on_mount {CyfrWeb.ContextGuard, :protected}

  # `CyfrWeb.ContextGuard` established the session, focused on the page's
  # athanor, and subscribed this bar to the person's standing; a session
  # the guard refuses never reaches here.
  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(CyfrWeb.SignInResponse.session_key())]
    ctx = socket.assigns.context
    ui_mode = Prism.Labels.mode(session["ui_mode"], ctx)

    if connected?(socket) do
      if ctx.platform_admin,
        do: Bus.subscribe_global(Bus.platform_notify())

      if is_binary(ctx.user_id),
        do: Bus.subscribe_global(Bus.file_offers(ctx.user_id))

      if ui_mode == "dev", do: subscribe_indicators(ctx)
      send(self(), :load_topbar)
    end

    surface = PrismWeb.Surface.read(session["surface"])
    page = if connected?(socket), do: kept_page(token, surface, session["page"])
    # Named as people are named (`Sanctum.Tenancy.Users.display_name/1`),
    # never by their id.
    person = if connected?(socket), do: Sanctum.Tenancy.Users.display_name(ctx.user_id)

    # Use cheap defaults for the disconnected render. Defer database reads,
    # cache writes and tool calls to the connected mount.
    {:ok,
     socket
     |> assign(:personal_namespace_slug, ctx.namespace)
     |> assign(:person, person)
     |> assign(:authenticated, true)
     |> assign(:ui_mode, ui_mode)
     |> assign(:athanor_route, PrismWeb.Focus.route_of(ctx))
     |> assign(:surface, surface)
     |> assign(:dashboard_path, dashboard_path(ui_mode, page, PrismWeb.Focus.route_of(ctx)))
     |> assign(:platform_requests, 0)
     |> assign(:offers_waiting, 0)
     |> assign(:open_popover, nil)
     |> assign(:system_status, nil)
     |> assign(:running_requests, [])
     |> assign(:running_executions, [])
     |> assign(:log_stats, %{total: 0, errors: 0, avg_duration_ms: 0, error_rate: 0.0})
     |> assign(:upcoming_schedules, [])
     |> assign(:in_flight_builds, [])
     |> assign(:recent_tinctures, [])
     |> assign(:refresh_pending, MapSet.new()), layout: false}
  end

  # The live indicators are dev's: their fan-in is subscribed only there.
  defp subscribe_indicators(ctx) do
    actor = Sanctum.Context.actor(ctx)

    for topic <- [
          Bus.requests(actor),
          Bus.executions(actor),
          Bus.schedule_runs(actor),
          Bus.feed_runs(actor),
          Bus.builds(actor),
          Bus.tinctures(actor)
        ] do
      Bus.subscribe(actor, topic)
    end
  end

  # How many people wait at the door — an operator's number, nobody else's.
  defp platform_requests(%{platform_admin: true}), do: length(Sanctum.Door.Store.requests())
  defp platform_requests(_ctx), do: 0

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

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info(:load_topbar, socket) do
    ctx = socket.assigns.context

    socket =
      socket
      |> assign(:platform_requests, platform_requests(ctx))
      |> load_offers_waiting()
      |> load_initial_state()

    {:noreply, socket}
  end

  @impl true
  def handle_info(%Bus.Request{}, socket) do
    {:noreply, refresh(socket, [:requests, :log_stats])}
  end

  def handle_info(%Bus.Tinctures{kind: :invoke_started} = invoked, socket) do
    {:noreply, socket |> add_recent_tincture(invoked, :started) |> refresh([:requests])}
  end

  def handle_info(%Bus.Tinctures{kind: :invoke_stopped} = invoked, socket) do
    {:noreply, socket |> add_recent_tincture(invoked, :stopped) |> refresh([:requests])}
  end

  def handle_info(%Bus.Tinctures{}, socket), do: {:noreply, socket}

  def handle_info(%Bus.Execution{}, socket) do
    {:noreply, refresh(socket, [:executions])}
  end

  def handle_info(%Bus.ScheduleRun{kind: :fired}, socket) do
    {:noreply, refresh(socket, [:schedules, :requests])}
  end

  def handle_info(%Bus.ScheduleRun{}, socket), do: {:noreply, socket}

  # A feed's fire refreshes what a schedule's does: it is a running
  # request too.
  def handle_info(%Bus.FeedRun{kind: :fired}, socket) do
    {:noreply, refresh(socket, [:schedules, :requests])}
  end

  def handle_info(%Bus.FeedRun{}, socket), do: {:noreply, socket}

  def handle_info(:do_refresh, socket) do
    pending = socket.assigns.refresh_pending

    socket =
      Enum.reduce(@refresh_order, socket, fn key, acc ->
        if MapSet.member?(pending, key), do: reload(key, acc), else: acc
      end)

    {:noreply, assign(socket, :refresh_pending, MapSet.new())}
  end

  def handle_info(%Bus.Build{kind: :started} = build, socket) do
    {:noreply, track_build_started(socket, build)}
  end

  def handle_info(%Bus.Build{kind: :progress}, socket), do: {:noreply, socket}

  def handle_info(%Bus.Build{kind: :stopped} = build, socket) do
    {:noreply, track_build_stopped(socket, build)}
  end

  # The door's queue changed: an operator's chip re-counts.
  def handle_info(%Notify{athanor_id: :platform}, socket) do
    {:noreply, assign(socket, :platform_requests, platform_requests(socket.assigns.context))}
  end

  # An offer of several files is announced once per file: the messages
  # already queued behind this one ask for the same count.
  def handle_info(%Bus.FileOffer{}, socket) do
    drain_offer_messages()
    {:noreply, load_offers_waiting(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp drain_offer_messages do
    receive do
      %Bus.FileOffer{} -> drain_offer_messages()
    after
      0 -> :ok
    end
  end

  # ============================================================================
  # Loaders
  # ============================================================================

  # Telemetry arrives in bursts — one request fans out to several events —
  # and this bar is mounted on EVERY page, so an unthrottled reload here is
  # the most-multiplied read in the console. Each event marks the indicators
  # its data invalidates; one timer drains the set 250 ms later, so a burst
  # costs one round of tool calls instead of two per event. `ActivitiesLive`
  # and `ExecutionsLive` coalesce their own refreshes the same way.
  defp refresh(socket, keys) do
    was_idle = MapSet.size(socket.assigns.refresh_pending) == 0
    if was_idle, do: Process.send_after(self(), :do_refresh, @refresh_window_ms)

    update(socket, :refresh_pending, &MapSet.union(&1, MapSet.new(keys)))
  end

  defp reload(:requests, socket), do: load_running_requests(socket)
  defp reload(:executions, socket), do: load_running_executions(socket)
  defp reload(:log_stats, socket), do: load_log_stats(socket)
  defp reload(:schedules, socket), do: load_upcoming_schedules(socket)

  # How many offers wait for the person, as the Files page lists them. A
  # count that cannot be read keeps the one the bar last showed.
  defp load_offers_waiting(socket) do
    case call_tool(socket, "file/offers", %{}) do
      {:ok, %{inbox: inbox}} ->
        assign(socket, :offers_waiting, length(PrismWeb.FilesLive.awaiting(inbox)))

      _unread ->
        socket
    end
  end

  defp load_initial_state(socket) do
    if socket.assigns[:authenticated] and socket.assigns[:ui_mode] == "dev" do
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
    case call_tool(socket, "system/status", %{}) do
      {:ok, status} -> assign(socket, :system_status, status)
      _ -> assign(socket, :system_status, %{})
    end
  end

  defp load_running_requests(socket) do
    case call_tool(socket, "mcp_log", %{
           "action" => "list",
           "limit" => @recent_requests_limit,
           "status" => "pending"
         }) do
      {:ok, %{logs: logs}} when is_list(logs) -> assign(socket, :running_requests, logs)
      _ -> assign(socket, :running_requests, [])
    end
  end

  defp load_running_executions(socket) do
    case call_tool(socket, "execution", %{
           "action" => "list",
           "status" => "running",
           "limit" => 20
         }) do
      {:ok, %{executions: list}} when is_list(list) -> assign(socket, :running_executions, list)
      _ -> assign(socket, :running_executions, [])
    end
  end

  defp load_log_stats(socket) do
    case call_tool(socket, "mcp_log", %{"action" => "stats"}) do
      {:ok, stats} ->
        assign(socket, :log_stats, %{
          total: stats[:total] || 0,
          errors: stats[:errors] || 0,
          avg_duration_ms: stats[:avg_duration_ms] || 0,
          error_rate: stats[:error_rate] || 0.0
        })

      _ ->
        socket
    end
  end

  defp load_upcoming_schedules(socket) do
    case call_tool(socket, "schedule", %{"action" => "list"}) do
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

  # ============================================================================
  # In-memory feeds
  # ============================================================================

  defp add_recent_tincture(socket, %Bus.Tinctures{} = invoked, lifecycle) do
    entry = %{
      request_id: invoked.request_id,
      tincture_ref: invoked.tincture_ref,
      reference: invoked.reference,
      status: lifecycle_status(lifecycle, invoked),
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

  defp track_build_started(socket, %Bus.Build{} = build) do
    entry = %{
      build_id: build.build_id,
      reference: build.reference,
      ts: System.system_time(:millisecond)
    }

    list =
      [entry | socket.assigns.in_flight_builds]
      |> Enum.uniq_by(& &1.build_id)
      |> Enum.take(@max_in_flight_builds)

    assign(socket, :in_flight_builds, list)
  end

  defp track_build_stopped(socket, %Bus.Build{} = build) do
    list =
      Enum.reject(socket.assigns.in_flight_builds, fn b -> b.build_id == build.build_id end)

    assign(socket, :in_flight_builds, list)
  end

  # ============================================================================
  # Display helpers
  # ============================================================================

  defp services_map(nil), do: %{}
  defp services_map(s) when is_map(s), do: s
  defp services_map(_), do: %{}

  defp schedule_active?(s) do
    enabled = s[:enabled]
    is_nil(enabled) or enabled == true
  end

  defp next_run_sort_key(s) do
    next = s[:next_run_at]

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
    services = services_map(f(assigns.system_status, :services))

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:running_requests_count, length(assigns.running_requests))
      |> assign(:running_executions_count, length(assigns.running_executions))
      |> assign(:next_schedule, List.first(assigns.upcoming_schedules))
      |> assign(:builds_count, length(assigns.in_flight_builds))
      |> assign(:tincture_count, length(assigns.recent_tinctures))

    ~H"""
    <div class="relative flex h-12 items-center justify-between gap-2 border-b border-gray-800 bg-gray-900 px-3 text-xs">
      <%!-- The bar is a nested LiveView with no layout: a flash it puts is
            rendered here, under the bar, or nowhere. --%>
      <div
        :for={kind <- [:error, :info]}
        :if={Phoenix.Flash.get(@flash, kind)}
        id={"topbar-flash-#{kind}"}
        role="alert"
        phx-click="lv:clear-flash"
        phx-value-key={kind}
        class={[
          "absolute left-1/2 top-12 z-40 mt-1 -translate-x-1/2 cursor-pointer rounded px-3 py-1.5 text-xs shadow-lg",
          kind == :error && "bg-red-900/90 text-red-100",
          kind == :info && "bg-gray-800 text-gray-100"
        ]}
      >
        {Phoenix.Flash.get(@flash, kind)}
      </div>
      <!-- The drawer, the brand, the person's AQUA -->
      <div class="flex items-center gap-2 lg:w-[15rem] lg:pl-1">
        <button
          :if={@authenticated}
          type="button"
          id="open-drawer"
          phx-click={Phoenix.LiveView.JS.show(to: "#drawer")}
          hidden={@surface == "canvas"}
          class={[
            "rounded-md p-1.5 text-gray-400 hover:bg-gray-800 hover:text-gray-200",
            if(@ui_mode == "dev", do: "lg:hidden", else: "")
          ]}
          aria-label="Open menu"
          title="Menu"
        >
          <.icon name="grid" class="h-5 w-5" />
        </button>
        <.link navigate="/" class="flex items-center gap-2">
          <img src={~p"/images/logo.jpg"} alt="CYFR" class="h-7 w-7 rounded-md" />
          <span class="text-lg font-bold text-white tracking-tight">CYFR</span>
        </.link>
        <.link
          :if={@authenticated}
          id="aqua-link"
          navigate={PrismWeb.Focus.path(@athanor_route, "/aqua")}
          class="rounded-md px-2 py-1 text-xs font-medium uppercase tracking-wider text-gray-300 hover:bg-gray-800/60 hover:text-gray-200"
        >
          AQUA
        </.link>
      </div>

      <nav
        :if={@authenticated}
        id="mode-switch"
        phx-hook="ModeSwitch"
        aria-label="Mode"
        title="Switch with Ctrl+Alt+`"
        class="flex shrink-0 items-center rounded-lg border border-gray-800 bg-gray-950 p-0.5"
      >
        <.link
          :for={
            {surface, label, path} <- [
              {"dashboard", "Dashboard", @dashboard_path},
              {"canvas", "Canvas", PrismWeb.Surface.canvas_path(@athanor_route)}
            ]
          }
          id={"mode-#{surface}"}
          navigate={path}
          data-mode={surface}
          aria-current={if @surface == surface, do: "page"}
          class={[
            "rounded-md px-2.5 py-1 font-medium",
            if(@surface == surface,
              do: "bg-gray-800 text-white",
              else: "text-gray-400 hover:text-gray-200"
            )
          ]}
        >
          {label}
        </.link>
      </nav>

      <div class="flex items-center gap-2">
        <!-- Door requests: an operator's chip -->
        <.link
          :if={@platform_requests > 0}
          navigate={PrismWeb.Focus.path(@athanor_route, "/settings")}
          id="door-requests"
          class="inline-flex items-center gap-1 rounded-full bg-amber-500/20 px-2 py-0.5 text-[11px] text-amber-200 hover:bg-amber-500/30"
          title="People waiting for sign-in approval"
        >
          <span class="h-1.5 w-1.5 rounded-full bg-amber-400" />
          {@platform_requests} {if @platform_requests == 1, do: "request", else: "requests"}
        </.link>
        <!-- Files offered to the person and waiting for their answer -->
        <.link
          :if={@offers_waiting > 0}
          navigate={PrismWeb.Focus.path(@athanor_route, "/files")}
          id="file-offers"
          class="inline-flex items-center gap-1 rounded-full bg-blue-500/20 px-2 py-0.5 text-[11px] text-blue-200 hover:bg-blue-500/30"
          title="Files offered to you"
        >
          <span class="h-1.5 w-1.5 rounded-full bg-blue-400" />
          {@offers_waiting} {if @offers_waiting == 1, do: "offer", else: "offers"}
        </.link>
        <!-- Search: the palette, by click as well as ⌘⇧K -->
        <button
          :if={@authenticated}
          type="button"
          id="open-palette"
          phx-click={Phoenix.LiveView.JS.push("toggle", target: "#command-palette")}
          class="rounded-md p-1.5 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          aria-label="Search"
          title="Search (⌘⇧K)"
        >
          <.icon name="grid" class="h-4 w-4" />
        </button>
        <div :if={@ui_mode == "dev"} id="live-indicators" class="hidden md:flex items-center gap-2">
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
                navigate={PrismWeb.Surface.canvas_path(@athanor_route)}
                class="block mt-2 text-xs text-blue-400 hover:text-blue-300"
              >
                Open in Canvas →
              </.link>
            </:popover>
          </.indicator>

          <!-- Schedules -->
          <.indicator
            :if={@next_schedule}
            name="schedules"
            open={@open_popover == "schedules"}
            label={f(@next_schedule, :name)}
            icon="clock"
          >
            <:popover>
              <h4 class="text-xs font-medium text-gray-400 mb-2">Upcoming schedules</h4>
              <ul class="space-y-1 text-sm">
                <%= for s <- @upcoming_schedules do %>
                  <li class="flex items-center justify-between gap-2">
                    <span class="text-gray-300 truncate">{f(s, :name)}</span>
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
                navigate={PrismWeb.Focus.path(@athanor_route, "/activities")}
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
            label={f(@system_status, :version) || "—"}
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
                <div :if={f(@system_status, :version)}>
                  version:
                  <span class="text-gray-300 font-mono">
                    {f(@system_status, :version)}
                  </span>
                </div>
              </div>
            </:popover>
          </.indicator>
        </div>

        <!-- Lock: a box's own screen, unlocked by its shell, locks there -->
        <form
          :if={PrismWeb.DeviceUnlockController.shell?(@context)}
          method="post"
          action={PrismWeb.DeviceUnlockController.lock_url()}
          data-test="device-lock"
        >
          <button
            type="submit"
            class="flex items-center gap-2 rounded-md border border-gray-700 px-3 py-1.5 text-xs text-gray-200 hover:bg-gray-800 hover:text-white transition-colors"
          >
            <.icon name="lock" class="h-3.5 w-3.5" /> Lock
          </button>
        </form>

        <!-- User -->
        <.indicator
          :if={@context}
          name="user"
          open={@open_popover == "user"}
          label={@person}
          icon="user"
        >
          <:popover>
            <dl class="space-y-2 text-sm">
              <div :if={@personal_namespace_slug}>
                <dt class="text-xs text-gray-500 uppercase">Namespace</dt>
                <dd class="text-white font-mono text-xs truncate">{@personal_namespace_slug}</dd>
              </div>
              <div :if={@context.email}>
                <dt class="text-xs text-gray-500 uppercase">Email</dt>
                <dd class="text-white text-xs truncate">{@context.email}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">Provider</dt>
                <dd class="text-white text-xs">{@context.provider}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500 uppercase">User ID</dt>
                <dd class="text-gray-400 font-mono text-[11px] break-all">{@context.user_id}</dd>
              </div>
            </dl>
            <.link
              href={~p"/auth/logout"}
              method="post"
              class="mt-3 flex items-center justify-center gap-2 rounded-md border border-gray-700 px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800 hover:text-white transition-colors"
            >
              <.icon name="logout" class="h-3.5 w-3.5" /> Sign out
            </.link>
          </:popover>
        </.indicator>
      </div>
    </div>
    """
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

  # The mode this bar's page is in, remembered for the browser session,
  # and the Dashboard page the Dashboard half leads back to: this page in
  # the Dashboard, the one remembered in the Canvas.
  defp kept_page(token, "canvas", _page) do
    PrismWeb.Surface.remember(token, "canvas")
    PrismWeb.Surface.recall(token).page
  end

  defp kept_page(token, "dashboard", page) do
    PrismWeb.Surface.remember(token, "dashboard", page)
    page
  end

  # The Dashboard page a nav key names, or the chat for none.
  defp dashboard_path(ui_mode, page, route) do
    case Enum.find(PrismWeb.Nav.items(ui_mode), &(&1.key == page)) do
      %{path: path} -> PrismWeb.Nav.href(path, route)
      nil -> PrismWeb.Nav.href("/chat", route)
    end
  end
end
