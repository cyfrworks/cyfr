# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TopbarLive do
  @moduledoc """
  The chrome — a nested LiveView mounted via `live_render` in the app
  layout, remounted with every page: the brand, the athanor switcher (You,
  then your groups; the one create, New group…), the drawer button, a
  search icon for the palette, the person, and — for a platform admin —
  how many door requests wait.

  In `dev` it also carries the live indicators, each a small icon/badge
  with a click-to-expand popover:

  | Indicator   | Source                 | Subscribes              |
  |-------------|------------------------|-------------------------|
  | Health      | system/status          | (loaded on mount)       |
  | Activity    | mcp_log/list           | prism:requests + tinctures + schedules |
  | Executions  | execution/list         | prism:executions        |
  | Rate        | mcp_log/stats          | prism:requests          |
  | Schedules   | schedule/list          | prism:schedules         |
  | Builds      | telemetry-only         | prism:builds            |
  | Tinctures   | telemetry-only         | prism:tinctures         |
  | User        | the session            |                         |

  Builds and Tinctures hide entirely when there's nothing to show, so the
  bar stays compact in normal operation. `lite` shows none of them: the
  chat is the page.

  The tray — badges on the switcher rows for what happened in an athanor
  while the person was elsewhere — is `Prism.Tray`, per session, so it
  survives the remounts; reading an estate in the chat clears its count.
  Which estate is being looked at is `@viewing`: the focused one on a
  workbench page, and on the chat page whichever estate the page has open
  — the chat says so (`viewing/2`) each time it moves, since it moves by
  patch and this bar does not remount for a patch.
  """

  use PrismWeb, :live_view

  alias Cyfr.Topics

  @recent_requests_limit 5
  @recent_tincture_limit 5
  @max_in_flight_builds 5

  # The indicator refresh window and drain order; see `refresh/2`.
  @refresh_window_ms 250
  @refresh_order [:requests, :executions, :log_stats, :schedules]

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(PrismWeb.SignInResponse.session_key())]

    socket =
      case PrismWeb.AuthHelpers.authenticate_session(token, session["athanor_id"]) do
        {:ok, ctx} ->
          ui_mode = Prism.Labels.mode(session["ui_mode"], ctx)

          if connected?(socket) do
            # The person's own memberships change what the switcher lists.
            Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Tenancy.Members.topic(ctx.user_id))
            # The page this bar sits on says which estate it has in view.
            Phoenix.PubSub.subscribe(Emissary.PubSub, viewing_topic(socket.parent_pid))

            if ctx.platform_admin,
              do: Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.platform_topic())

            if ui_mode == "dev", do: subscribe_indicators(ctx)
          end

          # The dead render assigns only cheap defaults; every DB read,
          # cache write and tool call waits for the connected mount — this
          # LiveView renders on EVERY page, and the loads below (athanor
          # list, door queue, the dev indicators with their registry
          # health probe) used to run on the dead render AND again on
          # connect, putting up to two 3s-timeout HTTP calls on the first
          # byte of every page.
          socket =
            socket
            |> assign(:context, ctx)
            |> assign(:personal_namespace_slug, ctx.namespace)
            |> assign(:authenticated, true)
            |> assign(:tray_key, Prism.Tray.session_hash(token))
            |> assign(:ui_mode, ui_mode)
            |> assign(:athanor_route, PrismWeb.Focus.route_of(ctx))
            |> assign(:viewing, ctx.athanor_id)
            |> assign(:badges, %{})
            |> assign(:platform_requests, 0)
            |> assign(:athanors, [])
            |> assign(:labels, %{})

          if connected?(socket) do
            send(self(), :load_topbar)
          end

          socket

        # Every refusal renders as the signed-out topbar on purpose: this
        # is a nested layout LiveView on every page — redirecting here
        # would fight the page's own gate, which owns the bounce
        # (AuthHelpers.disposition/1).
        _ ->
          socket
          |> assign(:context, nil)
          |> assign(:personal_namespace_slug, nil)
          |> assign(:authenticated, false)
          |> assign(:tray_key, nil)
          |> assign(:ui_mode, Prism.Labels.mode(session["ui_mode"]))
          |> assign(:athanor_route, nil)
          |> assign(:viewing, nil)
          |> assign(:athanors, [])
          |> assign(:labels, %{})
          |> assign(:badges, %{})
          |> assign(:platform_requests, 0)
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
     |> assign(:refresh_pending, MapSet.new()), layout: false}
  end

  # The live indicators are dev's: their fan-in is subscribed only there.
  defp subscribe_indicators(ctx) do
    for topic <- [
          Topics.requests(ctx),
          Topics.executions(ctx),
          Topics.schedule_runs(ctx),
          Topics.builds(ctx),
          Topics.tinctures(ctx)
        ] do
      Phoenix.PubSub.subscribe(Emissary.PubSub, topic)
    end
  end

  # How many people wait at the door — an operator's number, nobody else's.
  defp platform_requests(%{platform_admin: true}), do: length(Sanctum.Door.Store.requests())
  defp platform_requests(_ctx), do: 0

  @doc """
  Tell the bar over page `host` (the LiveView it is rendered in) that
  `athanor_id` is the estate in view — the chat calls it as it moves
  between estates, and after it has read the estate's tray count.
  """
  @spec viewing(pid(), String.t()) :: :ok | {:error, term()}
  def viewing(host, athanor_id) when is_pid(host) and is_binary(athanor_id) do
    Phoenix.PubSub.broadcast(Emissary.PubSub, viewing_topic(host), {:viewing, athanor_id})
  end

  @doc "The topic a page tells its own bar what it has in view on."
  @spec viewing_topic(pid() | nil) :: String.t()
  def viewing_topic(host) when is_pid(host),
    do: "topbar:viewing:" <> List.to_string(:erlang.pid_to_list(host))

  # A bar rendered with no page over it (a test mount) listens to nobody.
  def viewing_topic(nil), do: "topbar:viewing:none"

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
  # the only member. The chat opens on the new estate — named in the
  # address, since the session's default is still the previous one.
  def handle_event("create_group", %{"name" => name}, socket) do
    case call_tool(socket, "athanor/create", %{"name" => String.trim(name)}) do
      {:ok, %{route: route}} when is_binary(route) ->
        {:noreply, push_navigate(socket, to: PrismWeb.ChatLive.chat_path(route))}

      {:ok, _} ->
        {:noreply, socket |> assign(:open_popover, nil) |> load_athanors(socket.assigns.context)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not create the group: #{error_message(reason)}")}
    end
  end

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info(:load_topbar, socket) do
    ctx = socket.assigns.context

    socket =
      socket
      # The counts as the session left them: reading an estate in the chat
      # is what clears one, and the chat has done so before this bar loads.
      |> assign(:badges, Prism.Tray.get(socket.assigns.tray_key))
      |> assign(:platform_requests, platform_requests(ctx))
      |> load_athanors(ctx)
      |> load_initial_state()

    {:noreply, socket}
  end

  # The chat moved to another estate (and cleared its count on the way):
  # follow it, and re-read the tray rather than trust the copy held here.
  # Only an estate this person holds a seat in — the set the rows and the
  # badges are drawn from — can be the one in view.
  # The chat moves between estates by `push_patch`; the bar's name AND its
  # links follow, so every page the bar offers is the viewed estate's.
  def handle_info({:viewing, athanor_id}, socket) do
    known = Enum.map(socket.assigns.athanors, & &1.id)

    case Enum.find(socket.assigns.athanors, &(&1.id == athanor_id)) do
      %{} = athanor ->
        {:noreply,
         socket
         |> assign(:viewing, athanor_id)
         |> assign(:athanor_route, Sanctum.Tenancy.Athanors.route_slug(athanor))
         |> assign(:badges, socket.assigns.tray_key |> Prism.Tray.get() |> Map.take(known))}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:request, _meta, _meas}, socket) do
    {:noreply, refresh(socket, [:requests, :log_stats])}
  end

  def handle_info({:tincture_invoke_started, metadata, _meas}, socket) do
    {:noreply, socket |> add_recent_tincture(metadata, :started) |> refresh([:requests])}
  end

  def handle_info({:tincture_invoke_stopped, metadata, _meas}, socket) do
    {:noreply, socket |> add_recent_tincture(metadata, :stopped) |> refresh([:requests])}
  end

  def handle_info({:execution_started, _meta, _meas}, socket) do
    {:noreply, refresh(socket, [:executions])}
  end

  def handle_info({:execution_completed, _meta, _meas}, socket) do
    {:noreply, refresh(socket, [:executions])}
  end

  def handle_info({:execution_failed, _meta, _meas}, socket) do
    {:noreply, refresh(socket, [:executions])}
  end

  def handle_info({:schedule_fired, _meta, _meas}, socket) do
    {:noreply, refresh(socket, [:schedules, :requests])}
  end

  def handle_info(:do_refresh, socket) do
    pending = socket.assigns.refresh_pending

    socket =
      Enum.reduce(@refresh_order, socket, fn key, acc ->
        if MapSet.member?(pending, key), do: reload(key, acc), else: acc
      end)

    {:noreply, assign(socket, :refresh_pending, MapSet.new())}
  end

  def handle_info({:build_started, metadata, _meas}, socket) do
    {:noreply, track_build_started(socket, metadata)}
  end

  def handle_info({:build_progress, _meta, _meas}, socket), do: {:noreply, socket}

  def handle_info({:build_stopped, metadata, _meas}, socket) do
    {:noreply, track_build_stopped(socket, metadata)}
  end

  # The tray: one fan-in topic per athanor the person belongs to. Something
  # happening in an athanor that is not in view becomes a badge on its row;
  # the one in view shows its own live indicators. Only what wants a
  # person's attention badges: a card settled by someone else does not,
  # and an athanor renamed or reconfigured just redraws the list.
  def handle_info({:notify, _athanor_id, :approval_resolved, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    {:noreply, load_athanors(socket, socket.assigns.context)}
  end

  # The door's queue changed: an operator's chip re-counts.
  def handle_info({:notify, :platform, _kind, _payload}, socket) do
    {:noreply, assign(socket, :platform_requests, platform_requests(socket.assigns.context))}
  end

  # A notify that names a conversation is for that topic's FOLLOWERS: an
  # approval pending in a thread this person unfollowed does not light
  # their tray. The runner still broadcasts on the one athanor topic — the
  # filter lives at the reader, so no per-user topics exist and the tray
  # is where following becomes a notification fact.
  def handle_info({:notify, athanor_id, _kind, %{conversation_id: conv_id}}, socket)
      when is_binary(athanor_id) and is_binary(conv_id) do
    %{context: ctx, viewing: viewing} = socket.assigns

    cond do
      athanor_id == viewing ->
        {:noreply, socket}

      Arca.TopicSubscriptionStorage.follows?(athanor_id, conv_id, ctx.user_id) ->
        {:noreply, assign(socket, :badges, Prism.Tray.bump(socket.assigns.tray_key, athanor_id))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:notify, athanor_id, _kind, _payload}, socket) do
    if athanor_id == socket.assigns.viewing do
      {:noreply, socket}
    else
      badges = Prism.Tray.bump(socket.assigns.tray_key, athanor_id)
      {:noreply, assign(socket, :badges, badges)}
    end
  end

  def handle_info({:membership_changed, _change}, socket) do
    {:noreply, load_athanors(socket, socket.assigns.context)}
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
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

  # See `ExecutionsLive.short/1`: one truncation, in one unit.
  defp short(nil), do: ""
  defp short(s), do: truncate(s, 24)

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
      <!-- The drawer, the brand, the athanor in focus (the switcher: You, then your groups) -->
      <div class="flex items-center gap-2 lg:w-[15rem] lg:pl-1">
        <button
          :if={@authenticated}
          type="button"
          id="open-drawer"
          phx-click={Phoenix.LiveView.JS.show(to: "#drawer")}
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
            <span id="viewing-name" class="truncate text-xs font-medium">
              {Map.get(@labels, @viewing, "Estate")}
            </span>
            <span
              :if={badge_total(@badges, @viewing) > 0}
              class="h-2 w-2 rounded-full bg-blue-400 shrink-0"
            />
            <span :if={length(@athanors) > 1} class="text-gray-500">▾</span>
            <span :if={length(@athanors) <= 1} class="text-gray-600">+</span>
          </button>
          <div
            :if={@open_popover == "athanors"}
            phx-click-away="close_popover"
            class="absolute left-0 top-full mt-2 w-64 rounded-lg border border-gray-700 bg-gray-900 shadow-xl p-2 z-40"
          >
            <%!-- A row opens the estate's chat; its small AQUA link, the
                  workbench. --%>
            <ul :if={length(@athanors) > 1} class="space-y-0.5 text-sm">
              <li
                :for={a <- @athanors}
                class={[
                  "flex items-center gap-1 rounded-md pr-1",
                  if(a.id == @viewing,
                    do: "bg-gray-800 text-white",
                    else: "text-gray-300 hover:bg-gray-800/60"
                  )
                ]}
              >
                <.link
                  navigate={PrismWeb.ChatLive.chat_path(Sanctum.Tenancy.Athanors.route_slug(a))}
                  class="flex flex-1 min-w-0 items-center justify-between px-2 py-1.5"
                  aria-current={a.id == @viewing && "true"}
                >
                  <span class="truncate">
                    {Map.get(@labels, a.id, a.name)}
                    <span
                      :if={a.roster == "frozen"}
                      class="rounded bg-gray-800 px-1 text-[10px] text-gray-500 ml-1"
                      title="A DM — a frozen two-person estate"
                    >
                      DM
                    </span>
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
                <.link
                  navigate={PrismWeb.Focus.path(a, "/aqua")}
                  class="shrink-0 rounded px-1.5 py-1 text-[10px] uppercase tracking-wider text-gray-500 hover:bg-gray-700 hover:text-gray-200"
                  title={"Open the AQUA of " <> Map.get(@labels, a.id, a.name)}
                >
                  AQUA
                </.link>
              </li>
            </ul>
            <form
              phx-submit="create_group"
              class={[
                "flex items-center gap-1 px-1",
                if(length(@athanors) > 1, do: "mt-2 pt-2 border-t border-gray-800", else: "")
              ]}
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
        <!-- Door requests: an operator's chip -->
        <.link
          :if={@platform_requests > 0}
          navigate={PrismWeb.Focus.path(@athanor_route, "/settings")}
          id="door-requests"
          class="inline-flex items-center gap-1 rounded-full bg-amber-500/20 px-2 py-0.5 text-[11px] text-amber-200 hover:bg-amber-500/30"
          title="People waiting at the door"
        >
          <span class="h-1.5 w-1.5 rounded-full bg-amber-400" />
          {@platform_requests} {if @platform_requests == 1, do: "request", else: "requests"}
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
        
    <!-- User -->
        <.indicator
          :if={@context}
          name="user"
          open={@open_popover == "user"}
          label={@personal_namespace_slug || @context.email || @context.user_id}
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

  # The athanors the person may work in — their own first, then their
  # groups — each subscribed on its notify topic for the tray badges. An
  # athanor that has dropped off the list is unsubscribed: a seat that was
  # removed must stop badging, not keep reporting what happens in a furnace
  # its former member can no longer open.
  defp load_athanors(socket, ctx) do
    athanors = Sanctum.Tenancy.list_athanors(ctx)

    if connected?(socket) do
      ids = MapSet.new(athanors, & &1.id)
      previous = MapSet.new(socket.assigns[:athanors] || [], & &1.id)

      for gone <- MapSet.difference(previous, ids),
          do: Phoenix.PubSub.unsubscribe(Emissary.PubSub, Sanctum.Notify.topic(gone))

      for a <- athanors do
        Phoenix.PubSub.unsubscribe(Emissary.PubSub, Sanctum.Notify.topic(a.id))
        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(a.id))
      end
    end

    socket
    |> assign(:athanors, athanors)
    |> assign(:labels, Map.new(athanors, &{&1.id, row_label(&1, ctx)}))
    |> assign(:badges, Map.take(socket.assigns[:badges] || %{}, Enum.map(athanors, & &1.id)))
  end

  # Named once, at load: the person's own estate is "You", a DM is the
  # other person, a group its name — read here rather than in the render,
  # which would ask the store for every DM row on every paint.
  defp row_label(athanor, ctx), do: PrismWeb.Estates.label(athanor, ctx)

  defp badge_total(badges, viewing) do
    badges |> Map.delete(viewing) |> Map.values() |> Enum.sum()
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
