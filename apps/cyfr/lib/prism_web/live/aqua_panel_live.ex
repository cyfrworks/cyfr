# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLive do
  @moduledoc """
  The person's own AQUA, on every page: a floating button and, opened, a
  panel over the page onto their own athanor — the threads of You, one of
  them open as `PrismWeb.ThreadPaneLive` focused on You, whatever
  athanor the page is on.

  Opened beside a room (the chat page tells it what is in view through
  `PrismWeb.RoomFeed`), a send from here carries a bounded excerpt of the
  room's tape as context for the turn — read under the person's own
  membership, into the private thread only, never kept — and an answer
  can be pasted onto the room, attributed to the person. The pane does
  both; the panel names the room and holds the list.

  The panel is an overlay: it takes no room from the page, stands above
  every frame and tile and below the system layer, whose prompts the
  browser draws in its top layer. On the desk it moves and resizes
  (`AquaPanel`, `assets/js/aqua_panel/`, which reports each settled
  gesture as `place`) and docks to the right edge as a full-height
  sidebar (`dock`); in the hand it is a sheet from the bottom. Ctrl+J
  (`toggle`, from the `AquaPanelKeys` hook) opens and closes it, Escape
  from inside closes it, and a click elsewhere leaves it open.

  Nested in the app layout, so it rides every authenticated page — and
  remounts on every navigation. Whether it is open, which thread it
  shows, where it stands, its size and whether it is docked are kept per
  browser session (`Arca.Cache`, under a hash of the
  session token, the way `Prism.Tray` keeps its counts), so the panel a
  person opened on one page is the panel they find on the next. Nothing
  here reads the page's focus: the panel establishes the session itself
  and narrows to the person's own athanor. A person with no athanor of
  their own has no panel.

  The dead render is the button alone; the athanor and the kept state are
  read on the connected mount, once. `CyfrWeb.ContextGuard` establishes
  the session and keeps the panel's context current; the panel's move to
  the person's own athanor goes back through it (`refocus/2`).

  A grant the pane's turn needs is asked in the panel's own system layer
  (`PrismWeb.SystemLayer`, DOM id `system-layer-panel`), under the
  panel's context, which is the person's own athanor whatever athanor the
  page is on; the page's layer would commit in the page's. That layer
  opens no stream (`listen: false`): the page's own layer shows the
  person's confirmations, and none is drawn twice.
  """

  use PrismWeb, :live_view

  alias Arca.ThreadStorage, as: Threads
  alias Phoenix.LiveView.JS
  alias PrismWeb.SystemLayer
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Tenancy.Users

  @kept_ttl_ms :timer.hours(24)
  @layer "system-layer-panel"

  on_mount {CyfrWeb.ContextGuard, :protected}

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(CyfrWeb.SignInResponse.session_key())]
    room_feed = session["room_feed"]

    socket =
      socket
      |> assign(:phase, :pending)
      |> assign(:athanor, nil)
      |> assign(:kept, nil)
      |> assign(:open, false)
      |> assign(:place, nil)
      |> assign(:docked, false)
      |> assign(:threads, [])
      |> assign(:thread, nil)
      |> assign(:pane, nil)
      |> assign(:room, session["room"])
      |> assign(:room_feed, room_feed)
      |> assign(:ui_mode, session["ui_mode"])

    if connected?(socket) do
      if is_binary(room_feed), do: PrismWeb.RoomFeed.subscribe(room_feed)
      {:ok, socket |> own(token) |> restore(), layout: false}
    else
      {:ok, socket, layout: false}
    end
  end

  # Your own athanor, focused. The session's default is whatever page this
  # is on; the panel is always You. A person with no athanor of their own
  # gets nothing.
  defp own(socket, token) do
    ctx = socket.assigns.context

    with {:ok, id} <- Users.personal_athanor_id(ctx.user_id),
         {:ok, %{status: "active"} = athanor} <- Athanors.get(id),
         {:ok, focused} <- Sanctum.Context.focus(ctx, athanor),
         {:ok, refocused} <- CyfrWeb.ContextGuard.refocus(socket, focused) do
      refocused
      |> assign(:phase, :ready)
      |> assign(:athanor, athanor)
      |> assign(:kept, {:aqua_panel, Prism.Tray.session_hash(token)})
    else
      _ -> assign(socket, :phase, :none)
    end
  end

  # ============================================================================
  # What the session keeps: open or not, which thread, where it stands and
  # whether it is docked
  # ============================================================================

  defp restore(%{assigns: %{phase: :ready, kept: key}} = socket) do
    case Arca.Cache.get(key) do
      {:ok, %{open: open, thread_id: id} = kept} ->
        socket =
          socket
          |> assign(:place, kept[:place])
          |> assign(:docked, kept[:docked] == true)

        if open, do: open_on(socket, id), else: assign(socket, :thread, kept_thread(id))

      _ ->
        socket
    end
  end

  defp restore(socket), do: socket

  # Closed, the panel lists no threads; the kept id waits for the next open.
  defp kept_thread(nil), do: nil
  defp kept_thread(id), do: %{id: id}

  defp remember(%{assigns: %{kept: key} = assigns} = socket) do
    kept = %{
      open: assigns.open,
      thread_id: assigns.thread && assigns.thread.id,
      place: assigns.place,
      docked: assigns.docked
    }

    Arca.Cache.put(key, kept, @kept_ttl_ms)
    socket
  end

  # A placement the hook reports: whole CSS pixels, inside any screen, and
  # no smaller than the panel's minimum (the hook's own, in
  # `assets/js/aqua_panel/geometry.js`). Anything else is refused and the
  # kept placement stands.
  @min_w 300
  @min_h 360
  @max_px 100_000

  defp placement(%{"x" => x, "y" => y, "w" => w, "h" => h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and
              x in 0..@max_px and y in 0..@max_px and w in @min_w..@max_px and
              h in @min_h..@max_px,
       do: {:ok, %{x: x, y: y, w: w, h: h}}

  defp placement(_params), do: :error

  # The list is read when the panel opens, not on every page: closed, the
  # panel costs the page nothing. `nil` is the blank thread; an id the list
  # no longer holds falls back to it.
  defp open_on(socket, thread_id) do
    threads = Threads.list(Sanctum.Context.actor(socket.assigns.context))
    thread = Enum.find(threads, &(&1.id == thread_id))

    socket
    |> assign(:open, true)
    |> assign(:threads, threads)
    |> assign(:thread, thread)
    |> switch_pane(thread)
  end

  # The pane is one, turned to a thread by message once it has reported
  # in; closed, the panel has no pane, and the next open mounts one on the
  # kept thread.
  defp switch_pane(%{assigns: %{pane: pid}} = socket, thread) when is_pid(pid) do
    send(pid, {:switch_thread, thread && thread.id})
    socket
  end

  defp switch_pane(socket, _thread), do: socket

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("open", _params, socket) do
    id = socket.assigns.thread && socket.assigns.thread.id

    {:noreply, socket |> open_on(id) |> remember()}
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> assign(:open, false) |> assign(:pane, nil) |> remember()}
  end

  def handle_event("toggle", params, %{assigns: %{open: true}} = socket),
    do: handle_event("close", params, socket)

  def handle_event("toggle", params, socket), do: handle_event("open", params, socket)

  def handle_event("dock", _params, socket) do
    {:noreply, socket |> assign(:docked, not socket.assigns.docked) |> remember()}
  end

  def handle_event("place", params, socket) do
    case placement(params) do
      {:ok, place} -> {:noreply, socket |> assign(:place, place) |> remember()}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, socket |> open_on(blank_to_nil(id)) |> remember()}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(id), do: id

  # ============================================================================
  # What the page shows, and what the pane tells the panel
  # ============================================================================

  @impl true
  def handle_info(%Cyfr.Bus.RoomInView{room: room}, socket),
    do: {:noreply, assign(socket, :room, room)}

  # The pane is live: this is where a thread switch goes.
  def handle_info({:pane, _pane, {:ready, pid, thread_id}}, socket) do
    socket = assign(socket, :pane, pid)
    current = socket.assigns.thread && socket.assigns.thread.id

    if current != thread_id,
      do: {:noreply, switch_pane(socket, socket.assigns.thread)},
      else: {:noreply, socket}
  end

  # The pane's first message created the thread: it is the open one now.
  def handle_info({:pane, _pane, {:opened, thread}}, socket) do
    {:noreply, socket |> open_on(thread.id) |> remember()}
  end

  # The assistant pointed at a thread of You: the panel turns to it rather
  # than moving the page.
  def handle_info({:pane, _pane, {:open_thread, thread_id}}, socket) do
    {:noreply, socket |> open_on(thread_id) |> remember()}
  end

  # A grant the pane's turn needs: asked in the panel's own layer, under
  # the panel's context; the outcome goes back to the pane.
  def handle_info({:pane, _pane, {:grant, pid, prompt}}, socket) when is_pid(pid) do
    {:noreply, SystemLayer.relay(socket, pid, prompt, layer_id())}
  end

  def handle_info({:pane, _pane, _message}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{phase: :none} = assigns) do
    ~H"""
    <div id="aqua-panel-root"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="aqua-panel-root" phx-hook="AquaPanelKeys">
      <%!-- Above the composer's Send on the chat page, which sits in the
            corner the button would otherwise cover. The button and the
            panel stand above every layer the canvas draws (its full frame
            is z-50, its chrome up to z-60); the system layer's prompts are
            in the browser's top layer, above both. --%>
      <button
        id="aqua-panel-button"
        type="button"
        phx-click={if @open, do: "close", else: "open"}
        aria-expanded={to_string(@open)}
        aria-controls={@open && "aqua-panel-sheet"}
        aria-keyshortcuts="Control+J"
        title="Your own AQUA, on your own athanor wherever you are (Ctrl+J)"
        class="fixed bottom-20 right-4 z-[70] rounded-full bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-indigo-500"
      >
        AQUA
      </button>

      <%!-- Escape from inside the sheet (the hook's: the thread's own view
            keeps its keys from this view's bindings) and the × hand focus
            back to the button. The composer's hook takes focus when the
            sheet opens. Not modal, and NOT closed by a click elsewhere: the
            page under it stays live on purpose — it is the room being read
            and pasted into, and a click on the room to scroll or select a
            line must not take the panel away — so nothing traps focus here
            and nothing listens for a click outside. Its style is the hook's:
            it draws the placement there, and the server's patches leave
            it. --%>
      <aside
        :if={@open}
        id="aqua-panel-sheet"
        role="dialog"
        aria-label="Your AQUA"
        tabindex="-1"
        phx-hook="AquaPanel"
        phx-mounted={JS.ignore_attributes(["style", "data-aqua-moving"])}
        data-docked={to_string(@docked)}
        data-x={@place && @place.x}
        data-y={@place && @place.y}
        data-w={@place && @place.w}
        data-h={@place && @place.h}
        class="aqua-panel z-[70] flex flex-col border border-gray-800 bg-gray-950 shadow-2xl focus:outline-none"
      >
        <%!-- While a gesture runs it covers the whole viewport, so the
              pointer never passes over a frame, which would take it. --%>
        <div class="aqua-panel-shield" aria-hidden="true"></div>
        <div
          :for={edge <- ~w(n s e w ne nw se sw)}
          class="aqua-panel-edge"
          data-aqua-edge={edge}
          aria-hidden="true"
        >
        </div>
        <button
          type="button"
          class="aqua-panel-handle w-full"
          data-aqua-handle
          aria-label="Change height"
        >
          <span class="block h-1 w-10 rounded-full bg-gray-600"></span>
        </button>
        <header
          class="flex items-center gap-2 border-b border-gray-800 px-3 py-2"
          data-aqua-grip
        >
          <span class="shrink-0 text-sm font-medium text-gray-200">AQUA · You</span>
          <select
            id="aqua-panel-threads"
            name="id"
            phx-change="select"
            title="Your threads"
            aria-label="Your threads"
            class="min-w-0 flex-1 truncate rounded border border-gray-800 bg-gray-900 px-2 py-1 text-xs text-gray-300"
          >
            <option value="" selected={is_nil(@thread)}>New thread</option>
            <option
              :for={thread <- @threads}
              value={thread.id}
              selected={@thread && thread.id == @thread.id}
            >
              {thread.title}
            </option>
          </select>
          <button
            id="aqua-panel-dock"
            type="button"
            phx-click="dock"
            aria-pressed={to_string(@docked)}
            aria-label={if @docked, do: "Float over the page", else: "Pin to the right edge"}
            title={if @docked, do: "Float over the page", else: "Pin to the right edge"}
            class="aqua-panel-dock rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          >
            <svg
              class="h-4 w-4"
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              aria-hidden="true"
            >
              <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" />
              <path :if={not @docked} d="M10 2.5v11" />
              <rect :if={@docked} x="4.5" y="5.5" width="7" height="5" rx="1" />
            </svg>
          </button>
          <button
            id="aqua-panel-close"
            type="button"
            phx-click={close_and_return()}
            aria-label="Close"
            title="Close (Esc)"
            class="rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          >
            ×
          </button>
        </header>

        <p
          :if={@room}
          id="aqua-panel-room"
          title="What your AQUA reads with each message you send here"
          class="truncate border-b border-gray-800 px-3 py-1 text-[11px] text-gray-500"
        >
          Reading {PrismWeb.RoomFeed.label(@room)}
        </p>

        {live_render(@socket, PrismWeb.ThreadPaneLive,
          id: "aqua-panel-pane",
          container: {:div, class: "flex min-h-0 flex-1 flex-col"},
          session: %{
            "athanor_id" => @athanor.id,
            "thread_id" => @thread && @thread.id,
            "ui_mode" => @ui_mode,
            "panel" => true,
            "room_feed" => @room_feed,
            "room" => @room
          }
        )}
      </aside>

      <.live_component
        :if={@phase == :ready}
        module={SystemLayer}
        id={layer_id()}
        context={@context}
        listen={false}
        athanor_route={Athanors.route_slug(@athanor)}
        athanor_name={@athanor.name}
      />
    </div>
    """
  end

  defp close_and_return, do: JS.push("close") |> JS.focus(to: "#aqua-panel-button")

  @doc "The id of the panel's own system layer, beside the page's."
  @spec layer_id() :: String.t()
  def layer_id, do: @layer
end
