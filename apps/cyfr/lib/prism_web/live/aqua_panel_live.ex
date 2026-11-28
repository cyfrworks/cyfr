# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLive do
  @moduledoc """
  The person's own Aqua, over the desktop and every page drawn over it: a
  button at the shelf's right end and, opened, a panel onto their own
  athanor's daily thread, open as `PrismWeb.ThreadPaneLive`.

  Opened, the panel shows today's daily thread, made through the tool a
  headless client asks (`thread.today`). Only the person opening the
  panel makes it, here: the button, Ctrl+J, a panel a reload finds open,
  the desktop opening it on no thread, and its Today control; loading
  the desktop makes nothing. Earlier days are one step back by date: the
  header names the day shown by its date
  (`PrismWeb.DisplayHelpers.day_name/1`), its back control goes to the nearest
  earlier day that has a thread (`Arca.ThreadStorage.adjacent_day/3`),
  and its forward control and Today return.

  The button carries how many of today's posts the person has not seen
  (`Arca.ThreadStorage.unread/2`), none while today has no thread. It is
  read without making the thread, today's date in the person's zone
  (`Aqua.today/1`, `Arca.ThreadStorage.day/2`), and kept current from
  their list's announcements (`Cyfr.Bus.ThreadListed`, on their
  `Cyfr.Bus.threads/2` topic); the pane moves the read mark while it shows
  a thread. The panel follows the person's day: at each announcement of a
  daily thread it reads again the date now in their stored zone, so today
  moves forwards past midnight and backwards after a change of zone, and
  the thread of that date, made since by a send or a fire, is today's.
  Following it makes no thread.

  Opened beside a shared thread (the chat overlay, `PrismWeb.ChatOverlayLive`,
  tells it what it has open through `PrismWeb.RoomFeed`), a send from here
  carries a bounded excerpt of what was said there as context for the
  turn when the person ticks the pane's box for it — read under the
  person's own seat, into the daily thread only, never kept — and an
  answer can be pasted onto the shared thread, attributed to the person.
  The pane does both and names the shared thread. A crew member's thread
  is reached from its room. While the athanor's seeding has not finished
  the panel says so and offers to try it again (`athanor.provision`).

  The panel lists the person's workspace threads not archived, the latest
  activity first, whatever their state and whatever they have read, from
  their list of threads (`Aqua.threads/2`): each by its title, its state
  (`PrismWeb.DisplayHelpers.work_state/1`) and how many posts are new. One
  stays until it is archived. Its All threads control opens the whole
  list inside the panel: the daily, workspace and shared threads, an
  archived one marked, with a box that narrows it to the threads whose
  title holds what is typed (`Aqua.threads/2`'s `title:`, matched over
  every thread of theirs). A thread of the athanor chosen there is
  reached as any thread here is; a shared one opens in Chat, which the
  desktop opens at it. Both lists are read when they open and again,
  while the panel is open, when the person's list announces a workspace
  thread or a removal (a crew member's thread under one announces it
  too).

  A workspace thread is not shown in the panel: it opens as its own layer
  over the desktop (`PrismWeb.WorkspaceLive`). Asked for one, from the
  list, a card's Open in the pane or the desktop, the panel moves the
  page there through the desktop's `navigate`
  (`assets/js/hooks/shell_page.js`) and closes, the thread's posts being
  the layer's. A crew member's thread under a workspace thread moves the
  page to that layer and is shown here, over it.

  The desktop opens it for a canvas's `settings` of `aqua`, on today's
  thread, or at the thread a `ref` names: any thread of the person's
  athanor, an earlier day's or a crew member's included, and a workspace
  thread at its layer; and for its page key `threads` without a `ref`,
  on All threads.

  A page may ask it about something it shows (`Cyfr.Bus.AquaAsk`, on the
  page's own topic the session names, `aqua_ask`): a closed panel opens on
  today's thread, and its pane takes Prism's sentence after the draft the
  person has, attaching and sending nothing.

  The panel is an overlay: it takes no room from the page. Its order among
  the desktop's layers is `PrismWeb.CanvasLive`'s: above the frames, the
  shelf and a Dashboard page's overlay, its button at the shelf's right end
  (66) and the panel at 70 with the thread's menu inside it, under the
  command palette (80) and the system layer's prompts, which the browser
  draws in its top layer above every z-index. The thread's menu
  closes when the palette opens and goes with the panel when it closes.
  On the desk it moves and resizes
  (`AquaPanel`, `assets/js/aqua_panel/`, which reports each settled
  gesture as `place`) and docks to the right edge as a full-height
  sidebar (`dock`); in the hand it is a sheet from the bottom. Ctrl+J
  (`toggle`, from the `AquaPanelKeys` hook) opens and closes it, Escape
  from inside closes it, and a click elsewhere leaves it open.

  Nested in the desktop (`PrismWeb.ShellLive`), which stays while the
  person moves between the pages drawn over it, so the panel stays open
  across them; it remounts with the document. Whether it is open, where
  it stands, its size and whether it is docked are kept per browser
  session (`Arca.Cache`, under a hash of the session token), so the panel
  a person left open is the panel they find after a reload, on today's
  thread. Nothing here reads the page's focus: the panel establishes the
  session itself and narrows to the person's own athanor. A person with no
  athanor of their own has no panel.

  The dead render is the button alone; the athanor, today's count and the
  kept state are read on the connected mount, once.
  `CyfrWeb.ContextGuard` establishes the session and keeps the panel's
  context current; the panel's move to the person's own athanor goes back
  through it (`refocus/2`).

  A grant the pane's turn needs is asked in the panel's own system layer
  (`PrismWeb.SystemLayer`, DOM id `system-layer-panel`), under the
  panel's context, the person's own athanor. That layer opens no stream (`listen: false`): the page's own layer shows the
  person's confirmations, and none is drawn twice.
  """

  use PrismWeb, :live_view

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadListed
  alias Phoenix.LiveView.JS
  alias PrismWeb.SystemLayer
  alias Sanctum.Tenancy.Athanors

  @kept_ttl_ms :timer.hours(24)
  @layer "system-layer-panel"

  on_mount {CyfrWeb.ContextGuard, :protected}

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  @impl true
  def mount(_params, session, socket) do
    token = session[to_string(CyfrWeb.SignInResponse.session_key())]
    room_feed = session["room_feed"]
    aqua_ask = session["aqua_ask"]

    socket =
      socket
      |> assign(:phase, :pending)
      |> assign(:athanor, nil)
      |> assign(:kept, nil)
      |> assign(:open, false)
      |> assign(:place, nil)
      |> assign(:docked, false)
      |> assign(:thread, nil)
      |> assign(:day, nil)
      |> assign(:today, nil)
      |> assign(:unread, 0)
      |> assign(:earlier, false)
      |> assign(:works, [])
      |> assign(:all, nil)
      |> assign(:pane, nil)
      |> assign(:room, session["room"])
      |> assign(:room_feed, room_feed)
      |> assign(:ui_mode, session["ui_mode"])
      |> assign(:asked, nil)
      |> assign(:notice, nil)

    if connected?(socket) do
      if is_binary(room_feed), do: PrismWeb.RoomFeed.subscribe(room_feed)
      if is_binary(aqua_ask), do: Cyfr.Bus.subscribe_page(aqua_ask)
      # The desktop opens the panel for a canvas's `settings` of `aqua`.
      if pid = socket.parent_pid, do: send(pid, {:aqua_panel, self()})
      {:ok, socket |> own(token) |> restore(), layout: false}
    else
      {:ok, socket, layout: false}
    end
  end

  # Your own athanor, focused. A person with no athanor of their own gets
  # nothing.
  defp own(socket, token) do
    ctx = socket.assigns.context

    with {:ok, %{status: "active"} = athanor} <- Athanors.get_by_owner(ctx.user_id),
         {:ok, focused} <- Sanctum.Context.focus(ctx, athanor),
         {:ok, refocused} <- CyfrWeb.ContextGuard.refocus(socket, focused) do
      # The athanor's own notifications: its seeding ending, or a rename,
      # read again so the line saying it is still being set up goes. And
      # the person's list of threads, which keeps the button's count.
      actor = Sanctum.Context.actor(focused)
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.threads(actor, focused.user_id))

      refocused
      |> assign(:phase, :ready)
      |> assign(:athanor, athanor)
      |> assign(:kept, {:aqua_panel, token && Prima.Digest.sha256_hex(token)})
    else
      _ -> assign(socket, :phase, :none)
    end
  end

  # ============================================================================
  # What the session keeps: open or not, where it stands and whether it is
  # docked
  # ============================================================================

  # Closed, the panel reads today's count alone; a panel the session left
  # open is opened again.
  defp restore(%{assigns: %{phase: :ready, kept: key}} = socket) do
    case Arca.Cache.get(key) do
      {:ok, %{open: open} = kept} ->
        socket =
          socket
          |> assign(:place, kept[:place])
          |> assign(:docked, kept[:docked] == true)

        if open, do: open_on(socket, nil), else: count_today(socket)

      _ ->
        count_today(socket)
    end
  end

  defp restore(socket), do: socket

  defp remember(%{assigns: %{kept: key} = assigns} = socket) do
    kept = %{open: assigns.open, place: assigns.place, docked: assigns.docked}

    Arca.Cache.put(key, kept, @kept_ttl_ms)
    socket
  end

  # A placement the hook reports, in whole CSS pixels, with the viewport it
  # was made in (`vw`, `vh`, a screen's size from @min_viewport to
  # @max_viewport): it must lie inside that viewport and be no smaller than
  # the panel's minimum (the hook's own, in
  # `assets/js/aqua_panel/geometry.js`). Anything else is refused and the
  # kept placement stands. A client that misstates its viewport misplaces
  # only its own panel, which carries no authority; the hook fits a kept
  # placement to the current viewport when the panel opens.
  @min_w 300
  @min_h 360
  @min_viewport 320
  @max_viewport 16_000

  defp placement(%{"x" => x, "y" => y, "w" => w, "h" => h, "vw" => vw, "vh" => vh})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and
              is_integer(vw) and is_integer(vh) and vw in @min_viewport..@max_viewport and
              vh in @min_viewport..@max_viewport and x >= 0 and y >= 0 and w >= @min_w and
              h >= @min_h and x + w <= vw and y + h <= vh,
       do: {:ok, %{x: x, y: y, w: w, h: h, vw: vw, vh: vh}}

  defp placement(_params), do: :error

  # ============================================================================
  # Today, and the thread shown
  # ============================================================================

  # Today's daily thread as it stands, made by nothing here: its date in
  # the person's zone, the thread of that date if there is one, and how
  # many of its posts the person has not seen, none without one. Unread,
  # what was held stands.
  defp count_today(socket) do
    day = Aqua.today(socket.assigns.context)

    case Threads.day(actor(socket), day) do
      {:ok, today} -> socket |> assign(:day, day) |> held_today(today)
      {:error, :not_found} -> assign(socket, day: day, today: nil, unread: 0)
      {:error, _unread} -> socket
    end
  end

  # Today's daily thread, made if none: the person opened the panel on it.
  # The day may have turned since it was last read, so it is read again
  # whenever the panel opens or returns to today.
  defp make_today(socket) do
    with {:ok, %{id: id}} <- call_tool(socket, "thread/today", %{}),
         {:ok, today} <- Threads.get(actor(socket), id) do
      socket |> assign(:day, today.day) |> held_today(today)
    else
      _unmade -> socket
    end
  end

  defp held_today(socket, today) do
    case Threads.unread(actor(socket), today) do
      {:ok, unread} -> assign(socket, today: today, unread: unread)
      {:error, _unread} -> assign(socket, :today, today)
    end
  end

  # The panel opens on the thread `thread_id` names in the person's
  # athanor, reading today's as it stands, or on today's, made if none; a
  # workspace thread opens at its layer. The workspace threads are read
  # when it opens and whenever it turns: closed, the panel costs the page
  # nothing.
  defp open_on(socket, thread_id) do
    case own_thread(socket, thread_id) do
      %{} = thread -> socket |> count_today() |> assign(:open, true) |> reach(thread)
      nil -> socket |> assign(:open, true) |> show_today()
    end
  end

  # A thread of the person's, where it lives: a workspace thread is its
  # layer, to which the page moves while the panel closes; a crew member's
  # thread under one moves the page to that layer and is shown here, over
  # it; any other thread is shown here.
  defp reach(socket, %{kind: "workspace", id: id}) do
    socket
    |> go_to_workspace(id)
    |> assign(:open, false)
    |> assign(:pane, nil)
    |> remember()
  end

  defp reach(socket, %{kind: "crew", parent_id: parent} = thread) do
    case own_thread(socket, parent) do
      %{kind: "workspace", id: id} -> socket |> go_to_workspace(id) |> show(thread)
      _room -> show(socket, thread)
    end
  end

  defp reach(socket, thread), do: show(socket, thread)

  # The page moves to the workspace thread's layer through the desktop's
  # hook, which moves the page's LiveView on any view's `navigate` and
  # leaves the desktop and its frames as they are.
  defp go_to_workspace(socket, id) do
    to = PrismWeb.WorkspaceLive.address(Athanors.route_slug(socket.assigns.athanor), id)
    push_event(socket, "navigate", %{to: to})
  end

  defp show_today(socket) do
    socket = make_today(socket)
    show(socket, socket.assigns.today)
  end

  defp show(socket, thread) do
    socket
    |> assign(:thread, thread)
    |> assign(:earlier, earlier?(socket, thread))
    |> read_works()
    |> switch_pane(thread)
  end

  # The thread shown was deleted, `removed` itself or its room: a crew
  # member's thread whose room stands goes back to that room, and any
  # other to today's thread as the panel holds it, or to the blank slate
  # when today's is the one gone, where the next post makes it again. A
  # closed panel only keeps where its next open lands. An open one closes
  # the thread's menu, which its hook shows and hides, so the menu of the
  # thread that went does not stand over the one it lands on.
  defp leave(socket, removed) do
    landing =
      case socket.assigns.thread do
        %{kind: "crew", parent_id: room} when room != removed -> own_thread(socket, room)
        _room -> nil
      end || socket.assigns.today

    cond do
      not socket.assigns.open -> assign(socket, :thread, landing)
      landing -> socket |> close_menu() |> reach(landing)
      true -> socket |> close_menu() |> show(nil)
    end
  end

  defp close_menu(socket), do: push_event(socket, "aqua:close_menu", %{})

  # The person's workspace threads not archived, from their list of
  # threads read under the panel's context; a read that fails keeps what
  # was shown.
  defp read_works(socket) do
    case Aqua.threads(socket.assigns.context, kind: :workspace, archived: false) do
      {:ok, works} ->
        assign(socket, :works, works)

      {:error, _unread} ->
        socket
    end
  end

  # All threads, open: the whole list, narrowed to the title typed, read
  # under the panel's context; a read that fails keeps what was shown.
  defp read_all(%{assigns: %{all: %{title: title}}} = socket) do
    case Aqua.threads(socket.assigns.context, title: title) do
      {:ok, threads} -> assign(socket, :all, %{title: title, threads: threads})
      {:error, _unread} -> socket
    end
  end

  defp read_all(socket), do: socket

  defp read_works_if_open(%{assigns: %{open: true}} = socket),
    do: socket |> read_works() |> read_all()

  defp read_works_if_open(socket), do: socket

  defp show_all(socket), do: read_all(assign(socket, :all, %{title: nil, threads: []}))

  # What a typed title asks: nil for nothing but spaces.
  defp asked_title(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _typed -> text
    end
  end

  defp asked_title(_text), do: nil

  # Whether a daily thread has an earlier day to step back to.
  defp earlier?(socket, %{kind: "daily", day: %Date{} = day}),
    do: match?({:ok, _}, Threads.adjacent_day(actor(socket), day, :before))

  defp earlier?(_socket, _thread), do: false

  # A thread of the person's own athanor, read under the panel's context:
  # an id another athanor holds names nothing here.
  defp own_thread(socket, id) when is_binary(id) and id != "" do
    case Threads.get(actor(socket), id) do
      {:ok, thread} -> thread
      {:error, _none} -> nil
    end
  end

  defp own_thread(_socket, _id), do: nil

  defp actor(socket), do: Sanctum.Context.actor(socket.assigns.context)

  # The pane is one, turned to a thread by message once it has reported
  # in; closed, the panel has no pane, and the next open mounts one on the
  # thread shown.
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
    {:noreply, socket |> open_on(nil) |> remember()}
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     socket |> assign(:open, false) |> assign(:pane, nil) |> assign(:all, nil) |> remember()}
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

  # One step back or forward by day, from a daily thread: to the nearest
  # day that has a thread, forward to today's when none lies between.
  def handle_event("day_before", _params, %{assigns: %{thread: %{kind: "daily"}}} = socket) do
    case Threads.adjacent_day(actor(socket), socket.assigns.thread.day, :before) do
      {:ok, thread} -> {:noreply, show(socket, thread)}
      {:error, _none} -> {:noreply, socket}
    end
  end

  def handle_event("day_after", _params, %{assigns: %{thread: %{kind: "daily"}}} = socket) do
    case Threads.adjacent_day(actor(socket), socket.assigns.thread.day, :after) do
      {:ok, thread} -> {:noreply, show(socket, thread)}
      {:error, _none} -> {:noreply, show_today(socket)}
    end
  end

  def handle_event(step, _params, socket) when step in ["day_before", "day_after"],
    do: {:noreply, socket}

  def handle_event("today", _params, socket), do: {:noreply, show_today(socket)}

  # A workspace thread of the list opens at its layer.
  def handle_event("show_thread", %{"id" => id}, socket) do
    case own_thread(socket, id) do
      %{} = thread -> {:noreply, reach(socket, thread)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("all_threads", _params, %{assigns: %{all: nil}} = socket),
    do: {:noreply, show_all(socket)}

  def handle_event("all_threads", _params, socket), do: {:noreply, assign(socket, :all, nil)}

  def handle_event("search_threads", params, %{assigns: %{all: %{}}} = socket) do
    title = asked_title(params["title"])
    {:noreply, socket |> assign(:all, %{socket.assigns.all | title: title}) |> read_all()}
  end

  def handle_event("search_threads", _params, socket), do: {:noreply, socket}

  # A thread chosen from All threads, read under the panel's context: one
  # of the athanor is reached as any thread here is, and a shared one the
  # list holds opens in Chat, which the desktop opens at it.
  def handle_event(
        "choose_thread",
        %{"id" => id},
        %{assigns: %{all: %{threads: listed}}} = socket
      )
      when is_binary(id) do
    case own_thread(socket, id) do
      %{} = thread ->
        {:noreply, socket |> assign(:all, nil) |> reach(thread)}

      nil ->
        if Enum.any?(listed, &(&1.kind == :shared and &1.id == id)) and socket.parent_pid,
          do: send(socket.parent_pid, {:open_chat, id})

        {:noreply, assign(socket, :all, nil)}
    end
  end

  def handle_event("choose_thread", _params, socket), do: {:noreply, socket}

  # A seeding that failed is tried again by the person; the line says how
  # it went.
  def handle_event("provision", _params, socket) do
    notice =
      case call_tool(socket, "athanor/provision", %{}) do
        {:ok, _} -> nil
        {:error, reason} -> "Still not set up: #{error_message(reason)}"
      end

    {:noreply, socket |> reload_athanor() |> assign(:notice, notice)}
  end

  defp reload_athanor(socket) do
    case Athanors.get(socket.assigns.athanor.id) do
      {:ok, athanor} -> assign(socket, :athanor, athanor)
      _unread -> socket
    end
  end

  defp provisioning_note(athanor) do
    case Athanors.provisioning_failure(athanor) do
      nil ->
        nil

      %{step: step, detail: detail} ->
        detail =
          if String.length(detail) > 120, do: String.slice(detail, 0, 120) <> "…", else: detail

        "— last attempt failed at #{step}: #{detail}"
    end
  end

  # ============================================================================
  # What the page shows, and what the pane tells the panel
  # ============================================================================

  @impl true
  def handle_info(%Cyfr.Bus.RoomInView{room: room}, socket),
    do: {:noreply, assign(socket, :room, room)}

  # The page asked about something it shows: a closed panel opens on
  # today's thread, and the pane takes the sentence once it is live.
  def handle_info(%Cyfr.Bus.AquaAsk{sentence: sentence}, %{assigns: %{phase: :ready}} = socket) do
    socket = assign(socket, :asked, sentence)

    socket =
      if socket.assigns.open,
        do: socket,
        else: socket |> open_on(nil) |> remember()

    {:noreply, pass_asked(socket)}
  end

  def handle_info(%Cyfr.Bus.AquaAsk{}, socket), do: {:noreply, socket}

  # The pane is live: this is where a thread switch goes, and an ask
  # waiting for it is handed over.
  def handle_info({:pane, _pane, {:ready, pid, thread_id}}, socket) do
    socket = socket |> assign(:pane, pid) |> pass_asked()
    current = socket.assigns.thread && socket.assigns.thread.id

    if current != thread_id,
      do: {:noreply, switch_pane(socket, socket.assigns.thread)},
      else: {:noreply, socket}
  end

  # The pane asked for a thread of the person's: a crew member's thread or
  # its room, one the assistant pointed at, the daily thread a send joined,
  # or a card's workspace thread. The panel turns to it, or a workspace
  # thread opens at its layer.
  def handle_info({:pane, _pane, {:open_thread, thread_id}}, socket) do
    case own_thread(socket, thread_id) do
      %{} = thread -> {:noreply, reach(socket, thread)}
      nil -> {:noreply, socket}
    end
  end

  # A grant the pane's turn needs: asked in the panel's own layer, under
  # the panel's context; the outcome goes back to the pane.
  def handle_info({:pane, _pane, {:grant, pid, prompt}}, socket) when is_pid(pid) do
    {:noreply, SystemLayer.relay(socket, pid, prompt, layer_id())}
  end

  def handle_info({:pane, _pane, _message}, socket), do: {:noreply, socket}

  # The desktop opens the panel (a canvas's `settings` of `aqua`): on
  # today's thread, as the button does; once open, it stays as it is.
  def handle_info(:open, %{assigns: %{phase: :ready, open: false}} = socket) do
    {:noreply, socket |> open_on(nil) |> remember()}
  end

  def handle_info(:open, socket), do: {:noreply, socket}

  # The desktop opens the panel on All threads (its page key `threads`):
  # a closed panel opens on today's thread, as the button does, with the
  # whole list over it.
  def handle_info(:threads, %{assigns: %{phase: :ready}} = socket) do
    socket =
      if socket.assigns.open,
        do: socket,
        else: socket |> open_on(nil) |> remember()

    {:noreply, show_all(socket)}
  end

  def handle_info(:threads, socket), do: {:noreply, socket}

  # The desktop opens the panel at a thread (a canvas's `settings` of
  # `aqua` with a `ref`): any thread of the person's athanor, read under
  # their context, or today's when the id names none of theirs.
  def handle_info({:open, thread_id}, %{assigns: %{phase: :ready}} = socket)
      when is_binary(thread_id) do
    {:noreply, socket |> open_on(thread_id) |> remember()}
  end

  def handle_info({:open, _thread_id}, socket), do: {:noreply, socket}

  # Today's count as the person's list announces it, a read mark moved
  # among the changes, with the day read again (`follow_day/3`).
  def handle_info(
        %ThreadListed{kind: :daily, id: id, unread: unread},
        %{assigns: %{phase: :ready}} = socket
      ),
      do: {:noreply, follow_day(socket, id, unread)}

  # A workspace thread moved, was read or left: an open panel reads its
  # list again.
  def handle_info(%ThreadListed{kind: :workspace}, %{assigns: %{phase: :ready}} = socket),
    do: {:noreply, read_works_if_open(socket)}

  # A thread deleted: today's is made again by the next open, and the
  # thread shown, or the room of the crew member's thread shown, leaves
  # the panel (`leave/2`).
  def handle_info(%ThreadListed{kind: :removed, id: id}, socket) do
    socket =
      case socket.assigns do
        %{today: %{id: ^id}} -> socket |> assign(:today, nil) |> assign(:unread, 0)
        _assigns -> socket
      end

    case socket.assigns do
      %{thread: %{id: ^id}} -> {:noreply, leave(socket, id)}
      %{thread: %{parent_id: ^id}} -> {:noreply, leave(socket, id)}
      %{phase: :ready} -> {:noreply, read_works_if_open(socket)}
      _assigns -> {:noreply, socket}
    end
  end

  def handle_info(%ThreadListed{}, socket), do: {:noreply, socket}

  # The athanor moved: its seeding ended or it was renamed; read it again.
  def handle_info(
        %Cyfr.Bus.Notify{kind: :athanor_changed},
        %{assigns: %{phase: :ready}} = socket
      ),
      do: {:noreply, reload_athanor(socket)}

  def handle_info(%Cyfr.Bus.Notify{}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # The sentence goes to the pane once it is live: at once in an open
  # panel, and in one just opened when its pane reports in.
  defp pass_asked(%{assigns: %{asked: sentence, pane: pid}} = socket)
       when is_binary(sentence) and is_pid(pid) do
    send(pid, {:aqua_ask, sentence})
    assign(socket, :asked, nil)
  end

  defp pass_asked(socket), do: socket

  # The person's day, read again: the date now in their stored zone, and
  # the thread of that date. An announced daily thread of that date is
  # today's, with the count it carries; when the date moved and the
  # announced thread is another day's, today's is read as it stands. A
  # zone changed elsewhere, or midnight passed while the page stayed, moves
  # today either way. Nothing here makes a thread.
  defp follow_day(socket, id, unread) do
    day = Aqua.today(socket.assigns.context)

    case socket.assigns do
      %{today: %{id: ^id}, day: ^day} ->
        assign(socket, :unread, unread || 0)

      %{day: held} ->
        case own_thread(socket, id) do
          %{kind: "daily", day: ^day} = thread ->
            assign(socket, day: day, today: thread, unread: unread || 0)

          _another_day when held == day ->
            socket

          _another_day ->
            count_today(socket)
        end
    end
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
      <%!-- At the shelf's right end, after the chat's, in the shelf's
            chrome (`.shelf-end-button`). The panel stands where the
            moduledoc's order puts it. --%>
      <button
        id="aqua-panel-button"
        type="button"
        phx-click={if @open, do: "close", else: "open"}
        aria-expanded={to_string(@open)}
        aria-controls={@open && "aqua-panel-sheet"}
        aria-keyshortcuts="Control+J"
        title="Your own Aqua, on your own athanor wherever you are (Ctrl+J)"
        class="shelf-end-button"
      >
        <span class="aqua-panel-orb" aria-hidden="true"></span>
        Aqua
        <span
          :if={@unread > 0}
          id="aqua-panel-unread"
          class="shelf-end-count"
          aria-label={"#{@unread} new today"}
        >
          {@unread}
        </span>
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
        aria-label="Your Aqua"
        tabindex="-1"
        phx-hook="AquaPanel"
        phx-mounted={JS.ignore_attributes(["style", "data-aqua-moving"])}
        data-docked={to_string(@docked)}
        data-x={@place && @place.x}
        data-y={@place && @place.y}
        data-w={@place && @place.w}
        data-h={@place && @place.h}
        class="aqua-panel z-[70] flex flex-col text-text-primary focus:outline-none"
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
          <span class="block h-1 w-10 rounded-full bg-text-muted"></span>
        </button>
        <header
          class="flex h-[42px] shrink-0 items-center gap-2 border-b border-border-default pl-3 pr-2"
          data-aqua-grip
        >
          <span class="aqua-panel-orb" aria-hidden="true"></span>
          <span class="shrink-0 text-sm font-semibold">Aqua</span>
          <%!-- The day shown, a step back or forward by day, and Today. --%>
          <nav id="aqua-panel-day" aria-label="Days" class="ml-1 flex min-w-0 items-center gap-0.5">
            <button
              :if={daily?(@thread)}
              id="aqua-panel-day-before"
              type="button"
              phx-click="day_before"
              disabled={not @earlier}
              aria-label="The day before"
              title="The day before"
              class="aqua-panel-ghost text-sm disabled:opacity-30"
            >
              ‹
            </button>
            <span
              :if={@thread}
              id="aqua-panel-day-name"
              class="min-w-0 truncate text-xs text-text-secondary"
            >
              {thread_name(@thread)}
            </span>
            <button
              :if={daily?(@thread)}
              id="aqua-panel-day-after"
              type="button"
              phx-click="day_after"
              disabled={today?(@thread, @today)}
              aria-label="The day after"
              title="The day after"
              class="aqua-panel-ghost text-sm disabled:opacity-30"
            >
              ›
            </button>
            <button
              :if={not today?(@thread, @today)}
              id="aqua-panel-today"
              type="button"
              phx-click="today"
              class="ml-0.5 shrink-0 rounded-[7px] border border-border-default px-1.5 py-[2px] text-xs text-text-secondary hover:text-text-primary focus-visible:border-border-focus focus-visible:outline-none"
            >
              Today
            </button>
          </nav>
          <span class="flex-1"></span>
          <%!-- The thread's model, soul or role and usage: the pane's menu,
                which the panel's hook opens and closes. --%>
          <button
            id="aqua-panel-more"
            type="button"
            data-aqua-menu-toggle
            aria-controls="aqua-panel-pane-menu"
            aria-expanded="false"
            phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            aria-label="This thread's menu"
            title="This thread's menu"
            class="aqua-panel-ghost"
          >
            <svg class="h-3.5 w-3.5" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <circle cx="3" cy="8" r="1.4" />
              <circle cx="8" cy="8" r="1.4" />
              <circle cx="13" cy="8" r="1.4" />
            </svg>
          </button>
          <button
            id="aqua-panel-dock"
            type="button"
            phx-click="dock"
            aria-pressed={to_string(@docked)}
            aria-label={if @docked, do: "Float over the page", else: "Pin to the right edge"}
            title={if @docked, do: "Float over the page", else: "Pin to the right edge"}
            class="aqua-panel-dock aqua-panel-ghost"
          >
            <svg
              class="h-3.5 w-3.5"
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
            class="aqua-panel-ghost text-sm"
          >
            ×
          </button>
        </header>

        <div
          :if={is_nil(@athanor.provisioned_at)}
          id="aqua-panel-provisioning"
          class="flex shrink-0 items-center justify-between gap-2 border-b border-amber-900/60 bg-amber-950/40 px-3 py-1.5 text-xs text-amber-200"
        >
          <span class="min-w-0 truncate">
            Aqua is still being set up
            <span :if={note = provisioning_note(@athanor)} class="text-amber-300/80">{note}</span>
          </span>
          <button
            type="button"
            phx-click="provision"
            class="min-h-6 shrink-0 rounded bg-amber-800/60 px-2 py-0.5 text-xs text-amber-100 hover:bg-amber-700/80"
          >
            Retry
          </button>
        </div>

        <p
          :if={@notice}
          id="aqua-panel-notice"
          role="alert"
          class="shrink-0 border-b border-border-default px-3 py-1 text-[11px] text-red-300"
        >
          {@notice}
        </p>

        <%!-- The workspace threads not archived, whatever their state; each
              opens at its layer. --%>
        <ul
          :if={@works != []}
          id="aqua-panel-works"
          aria-label="Workspace threads"
          class="max-h-28 shrink-0 overflow-y-auto border-b border-border-default py-0.5"
        >
          <li :for={work <- @works} id={"aqua-panel-work-" <> work.id} data-state={work.state}>
            <button
              type="button"
              phx-click="show_thread"
              phx-value-id={work.id}
              title={work.title}
              class="flex min-h-6 w-full min-w-0 items-center gap-1.5 px-3 text-left text-xs text-text-secondary hover:text-text-primary"
            >
              <span class="min-w-0 truncate font-semibold">{work.title}</span>
              <span class={[
                "shrink-0",
                if(work.waits_on_you, do: "text-amber-300", else: "text-text-muted")
              ]}>
                {work_state(work.state)}
              </span>
              <span
                :if={work.unread > 0}
                class="shelf-end-count shrink-0"
                aria-label={"#{work.unread} new"}
              >
                {work.unread}
              </span>
            </button>
          </li>
        </ul>

        <button
          id="aqua-panel-all-threads"
          type="button"
          phx-click="all_threads"
          aria-expanded={to_string(@all != nil)}
          aria-controls={@all && "aqua-panel-threads"}
          class="flex min-h-6 w-full shrink-0 items-center border-b border-border-default px-3 text-left text-xs text-text-secondary hover:text-text-primary focus-visible:outline-none focus-visible:text-text-primary"
        >
          All threads
        </button>

        <%!-- Every thread of the person's: the athanor's daily and workspace
              threads, an archived one marked, and the shared threads they
              sit in, narrowed by a title typed. --%>
        <section
          :if={@all}
          id="aqua-panel-threads"
          aria-label="All threads"
          class="flex max-h-[45%] shrink-0 flex-col border-b border-border-default"
        >
          <form
            id="aqua-panel-threads-search"
            phx-change="search_threads"
            phx-submit="search_threads"
            class="shrink-0 px-3 py-1"
          >
            <input
              type="search"
              name="title"
              maxlength="100"
              value={@all.title}
              placeholder="Find a thread by its title"
              aria-label="Find a thread by its title"
              autocomplete="off"
              phx-debounce="200"
              class="w-full rounded-[7px] border border-border-default bg-transparent px-2 py-0.5 text-xs text-text-primary placeholder:text-text-muted focus-visible:border-border-focus focus-visible:outline-none"
            />
          </form>
          <p :if={@all.threads == []} class="px-3 py-1 text-xs text-text-muted">
            No thread has that title.
          </p>
          <ul class="min-h-0 overflow-y-auto py-0.5">
            <li
              :for={listed <- @all.threads}
              id={"aqua-panel-thread-" <> listed.id}
              data-kind={to_string(listed.kind)}
              data-archived={to_string(listed.archived)}
            >
              <button
                type="button"
                phx-click="choose_thread"
                phx-value-id={listed.id}
                class="flex min-h-6 w-full min-w-0 items-center gap-1.5 px-3 text-left text-xs text-text-secondary hover:text-text-primary"
              >
                <span class="min-w-0 truncate font-semibold">{listed_name(listed)}</span>
                <span :if={listed_kind(listed)} class="shrink-0 text-text-muted">
                  {listed_kind(listed)}
                </span>
                <span :if={listed.archived} class="shrink-0 text-text-muted">Archived</span>
                <span
                  :if={listed.unread > 0}
                  class="shelf-end-count shrink-0"
                  aria-label={"#{listed.unread} new"}
                >
                  {listed.unread}
                </span>
              </button>
            </li>
          </ul>
        </section>

        {live_render(@socket, PrismWeb.ThreadPaneLive,
          id: "aqua-panel-pane",
          container: {:div, class: "flex min-h-0 flex-1 flex-col"},
          session: %{
            "athanor_id" => @athanor.id,
            "thread_id" => @thread && @thread.id,
            "ui_mode" => @ui_mode,
            "room_feed" => @room_feed,
            "room" => @room,
            "entry" => @request_entry
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

  defp daily?(thread), do: match?(%{kind: "daily"}, thread)

  defp today?(%{id: id}, %{id: id}), do: true
  defp today?(_thread, _today), do: false

  # A daily thread by its day's date, a crew member's by its member, a
  # workspace thread by its title.
  defp thread_name(%{kind: "daily", day: day}), do: day_name(day)
  defp thread_name(%{kind: "crew", agent: agent}), do: "#{agent}'s thread"
  defp thread_name(%{title: title}), do: title

  # A thread of All threads by its name: a daily thread by its day's date
  # in words, a shared one with no title as what it is.
  defp listed_name(%{kind: :daily, title: title}) do
    case Date.from_iso8601(title || "") do
      {:ok, day} -> day_name(day)
      {:error, _not_a_date} -> title
    end
  end

  defp listed_name(%{kind: :shared, title: nil}), do: "A shared thread"
  defp listed_name(%{title: title}), do: title

  defp listed_kind(%{kind: :shared}), do: "Shared"
  defp listed_kind(%{kind: :workspace, state: state}), do: work_state(state)
  defp listed_kind(_daily), do: nil

  @doc "The id of the panel's own system layer, beside the page's."
  @spec layer_id() :: String.t()
  def layer_id, do: @layer
end
