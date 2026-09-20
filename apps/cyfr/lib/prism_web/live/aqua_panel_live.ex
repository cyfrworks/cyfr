# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLive do
  @moduledoc """
  The person's own AQUA, on every page: a floating button and, opened, a
  panel over the page onto their own athanor — the threads of You, one of
  them open as `PrismWeb.ThreadPaneLive` focused on You, whatever
  estate the page is on.

  Opened beside a room (the chat page tells it what is in view through
  `PrismWeb.RoomFeed`), a send from here carries a bounded excerpt of the
  room's tape as context for the turn — read under the person's own
  membership, into the private thread only, never kept — and an answer
  can be pasted onto the room, attributed to the person. The pane does
  both; the panel names the room and holds the list.

  Nested in the app layout, so it rides every authenticated page — and
  remounts on every navigation. Whether it is open and which thread it
  shows are kept per browser session (`Arca.Cache`, under a hash of the
  session token, the way `Prism.Tray` keeps its counts), so the panel a
  person opened on one page is the panel they find on the next. Nothing
  here reads the page's focus: the panel establishes the session itself
  and narrows to the person's own athanor. A person with no athanor of
  their own has no panel.

  The dead render is the button alone; the session, the athanor and the
  kept state are read on the connected mount, once.
  """

  use PrismWeb, :live_view

  alias Arca.ThreadStorage, as: Threads
  alias Phoenix.LiveView.JS
  alias Sanctum.Tenancy.Athanors
  alias Sanctum.Tenancy.Users

  @kept_ttl_ms :timer.hours(24)

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(PrismWeb.SignInResponse.session_key())]
    room_feed = session["room_feed"]

    socket =
      socket
      |> assign(:phase, :pending)
      |> assign(:context, nil)
      |> assign(:athanor, nil)
      |> assign(:kept, nil)
      |> assign(:open, false)
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
  # is on; the panel is always You. A session that no longer establishes
  # is said so; a person with no athanor of their own gets nothing.
  defp own(socket, token) do
    case PrismWeb.AuthHelpers.authenticate_session(token) do
      {:ok, ctx} ->
        with {:ok, id} <- Users.personal_athanor_id(ctx.user_id),
             {:ok, %{status: "active"} = athanor} <- Athanors.get(id),
             {:ok, focused} <- Sanctum.Context.focus(ctx, athanor) do
          socket
          |> assign(:phase, :ready)
          |> assign(:context, focused)
          |> assign(:athanor, athanor)
          |> assign(:kept, {:aqua_panel, Prism.Tray.session_hash(token)})
        else
          _ -> assign(socket, :phase, :none)
        end

      {:error, _} ->
        assign(socket, :phase, :signed_out)
    end
  end

  # ============================================================================
  # What the session keeps: open or not, and which thread
  # ============================================================================

  defp restore(%{assigns: %{phase: :ready, kept: key}} = socket) do
    case Arca.Cache.get(key) do
      {:ok, %{open: true, thread_id: id}} -> open_on(socket, id)
      _ -> socket
    end
  end

  defp restore(socket), do: socket

  defp remember(%{assigns: %{kept: key, open: open, thread: thread}} = socket) do
    Arca.Cache.put(key, %{open: open, thread_id: thread && thread.id}, @kept_ttl_ms)
    socket
  end

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

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, socket |> open_on(blank_to_nil(id)) |> remember()}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(id), do: id

  # ============================================================================
  # What the page shows, and what the pane tells the panel
  # ============================================================================

  @impl true
  def handle_info({:room_in_view, room}, socket), do: {:noreply, assign(socket, :room, room)}

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

  def handle_info({:pane, _pane, _message}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{phase: :signed_out} = assigns) do
    ~H"""
    <div id="aqua-panel-root">
      <p
        id="aqua-panel-signed-out"
        role="status"
        class="fixed bottom-20 right-4 z-40 rounded-full border border-gray-800 bg-gray-900 px-4 py-2 text-xs text-gray-400 shadow-lg"
      >
        Signed out — reload to continue
      </p>
    </div>
    """
  end

  def render(%{phase: :none} = assigns) do
    ~H"""
    <div id="aqua-panel-root"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="aqua-panel-root">
      <%!-- Above the composer's Send on the chat page, which sits in the
            corner the button would otherwise cover. --%>
      <button
        id="aqua-panel-button"
        type="button"
        phx-click={if @open, do: "close", else: "open"}
        aria-expanded={to_string(@open)}
        aria-controls={@open && "aqua-panel-sheet"}
        title="Your own AQUA — on your own estate, wherever you are"
        class="fixed bottom-20 right-4 z-40 rounded-full bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-lg hover:bg-indigo-500"
      >
        AQUA
      </button>

      <%!-- Escape (from inside the sheet) and the × hand focus back to the
            button. The composer's hook takes focus when the sheet opens. Not
            modal, and NOT closed by a click elsewhere: the page under it stays
            live on purpose — it is the room being read and pasted into, and a
            click on the room to scroll or select a line must not take the
            panel away — so nothing traps focus here and nothing listens for
            a click outside. --%>
      <aside
        :if={@open}
        id="aqua-panel-sheet"
        role="dialog"
        aria-label="Your AQUA"
        tabindex="-1"
        phx-keydown={close_and_return()}
        phx-key="Escape"
        class="fixed top-12 bottom-0 right-0 z-40 flex w-[28rem] max-w-full flex-col border-l border-gray-800 bg-gray-950 shadow-2xl focus:outline-none"
      >
        <header class="flex items-center gap-2 border-b border-gray-800 px-3 py-2">
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
            type="button"
            phx-click={close_and_return()}
            aria-label="Close"
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
    </div>
    """
  end

  defp close_and_return, do: JS.push("close") |> JS.focus(to: "#aqua-panel-button")
end
