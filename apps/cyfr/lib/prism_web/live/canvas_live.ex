# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLive do
  @moduledoc """
  The canvas layer: the person's layout read for the posture their client
  reports, every frame the shell holds (`Prism.Frames`) drawn where its
  placement puts it, the chrome the shell draws around each app, and the
  shelf.

  It reads the layout through `Compendium.layout/2` and draws the visible
  canvas's frame filling the apps' area (the layer above the shelf;
  a hidden canvas's frame is held invisible and frozen, and a validation
  frame is hidden and inert), narrowed by the tiles beside it; its tiles
  at their edge and share; its windows at their geometry; and the active
  `full` frame over everything, with its capsule. Geometry and shares are
  hundredths of a percent of the apps' area. While a full frame is shown
  every other layer is `inert`, so no key reaches a control it covers; the
  full frame and its capsule stay reachable.

  The page stacks by z-index alone, from the bottom: the canvas's frame
  (0); tiles (20); the windows shown, 30 plus each one's rank in the
  stacking order, whatever the layout's orders are (at most 32 apps, so up
  to 61); a full app (64); the canvas's own controls, 65 to 69 (the shelf
  65, the shell's own chips on it and the fallback's line after them 67,
  the layout note 68, the connection notice 69); the AQUA panel with its menu (70, `PrismWeb.AquaPanelLive`);
  the command palette (80); and the system layer's prompts, which the
  browser draws in its top layer above every z-index. Raising an app
  restyles its wrapper and never moves it. A window or tile raised above a
  full app hides it (`Prism.Frames`); the full app keeps its placement
  until it is raised again.

  Each app's wrapper carries what it stands as for the hook:
  `data-canvas-place` (`window`, `tile` or `full`), `data-canvas-stack`,
  `data-canvas-minimised`, `data-canvas-geometry` (`x y w h`) or
  `data-canvas-side` and `data-canvas-share`, `data-canvas-active` (the
  app the keys and the ring act on: the shown full app, or else the
  topmost shown window or tile), and what the app takes when it changes
  placement, from one rule here: a window's `data-canvas-tile-share` (the
  share it takes as a tile) and a tile's or full app's `data-canvas-window`
  (the geometry it takes as a window).

  A window or a tile wears the shell's chrome, drawn outside its iframe so
  no app draws or presses it: a title bar (`data-canvas-grip`, the app's
  icon and name, and four controls: minimise, tile or window, full and
  close, which push `frame_minimise`, `frame_tile` or `frame_move`,
  `frame_full` and `frame_close` to the shell), and the edges a window is
  resized from or the divider a tile is (`data-canvas-edge`). The hook
  turns a drag, a resize, a drop on a screen edge and the keys into the
  shell's arrangement events (`PrismWeb.ShellLive`), one per settled
  gesture.

  The shelf (`#canvas-shelf`, 52 pixels along the bottom, drawn with the
  visible canvas, and like the canvas's other
  controls above a full app and within reach) holds, from the left: room for
  the shell's own chips, which `PrismWeb.ShellLive` draws; with more than
  one canvas, a dot per canvas (`#canvas-switcher`, each a button carrying
  `data-canvas` that asks the shell to show it, `switch_canvas` with
  `canvas`, the current one pressed); the visible canvas's open apps
  (`data-canvas-shelf-app`, the active one marked, a minimised one dimmed;
  a click raises it, `frame_raise`, or restores it, `app_restore`); and
  room at the right end for the AQUA button the app layout draws. The hook
  reads a horizontal swipe on the shelf as a canvas switch. The shelf
  lists the apps the shell holds and the ones the shell's arrangement
  holds minimised.

  The posture is the client's: the `Canvas` hook (`assets/js/canvas/`)
  reports `hand` or `desk` as the event `posture`, and any other value is
  ignored. Before the first report the canvas draws `desk`. Each
  layout read is sent to the shell whole, as
  `{PrismWeb.CanvasLive, :layout, posture, read}` (`Compendium.layout/2`'s
  answer), and the shell opens, stands and discards frames for it
  (`Prism.Frames.arrange/5`); a read that fails is sent as
  `{PrismWeb.CanvasLive, :layout_unavailable}`. The canvas
  itself opens no frame and holds no credential. An update with
  `reload: true` reads the layout again.

  Assigns: `context`, `frames` (the shell's `Prism.Frames`), `tinctures`
  (the shell's tincture cards), `arrangement` (the shell's arrangement for
  the posture, `nil` before its first read, when this layer's own read
  stands in).

  The hook sits on an empty element of its own, `#<id>-hook`, after the
  frames, which carries `data-posture`; it reads the layer as that
  element's parent, and its pushes go from that element. It relays the
  shell's `frame_state`, `frame_credential` and `canvas_installed` pushes
  to each frame's bridge and sends each canvas frame its posture and the
  rectangles of the windows over it (a tile narrows the canvas's frame
  instead of covering it, and a full app's cover is the frozen state). A
  canvas or validation frame carries `data-frame-kind="canvas"`, so its
  bridge hands it the canvas's handshake and forwards its messages as a
  canvas's.

  An iframe is never moved in the document, since a moved frame reloads:
  no patch removes or re-inserts a held frame's iframe or any element
  around it, and only that frame's own discard removes it. The page's
  patch moves an element when an earlier sibling is removed or one whose
  presence varies appears or disappears before it, so the frames' wrappers
  are a stream: the only children of one `phx-update="stream"` container,
  where a patch updates a child in place and never re-adds it, and in each
  wrapper the iframe comes first, with the chrome or the capsule after it,
  so a placement that adds or drops them never moves the iframe. Every
  update streams each held frame, a wrapper already drawn patched where it
  stands and a new one appended, so frames keep the order they were opened
  in, and deletes the wrapper of each frame no longer held. In the layer
  the container follows only the geometry and status elements, which are
  always drawn; the hook's element, the layout note and the shelf follow
  it. The shell draws nothing whose presence varies before the layer.

  No element around the frames, up to the page's root, carries a hook or
  an event binding. The page locks the element an event is pushed from
  until its reply and patches a copy of it meanwhile; a wrapper deleted
  then is removed from the document but kept in the copy, which the reply
  puts back, and the discarded frame would load again. The chrome's
  controls are inside a wrapper, never around one.
  """

  use PrismWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Prism.Frames

  @postures Prima.Layout.postures()
  @max_fraction 10_000
  # Tiles stand at 20 beside the canvas (0), the windows shown from 30 by
  # their rank.
  @tile_z 20
  @window_z 30

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       posture: "desk",
       loaded: nil,
       arrangement: nil,
       read: nil,
       layout_unavailable: false,
       frames: Frames.new(),
       streamed: nil,
       tinctures: []
     )}
  end

  @impl true
  def update(%{reload: true} = assigns, socket) do
    update(Map.delete(assigns, :reload), assign(socket, :loaded, nil))
  end

  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> stream_frames()

    if connected?(socket) and socket.assigns.loaded != socket.assigns.posture do
      {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, load(&1)})
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("posture", %{"posture" => posture}, socket) when posture in @postures do
    if posture == socket.assigns.posture do
      {:noreply, socket}
    else
      CyfrWeb.ContextGuard.guard(socket, fn socket ->
        {:noreply, socket |> assign(:posture, posture) |> load()}
      end)
    end
  end

  def handle_event("posture", _params, socket), do: {:noreply, socket}

  # Every frame held, streamed: a wrapper already drawn is updated where it
  # stands, a new one is appended after the rest, and the wrapper of a
  # frame no longer held is deleted. A wrapper is never deleted and
  # inserted in one update, which would re-insert it. The stream's ids are
  # the wrappers', so it is configured once the component's id is known.
  defp stream_frames(%{assigns: %{streamed: nil, id: id}} = socket) do
    socket
    |> stream_configure(:frames, dom_id: &wrapper_id(id, &1.id))
    |> stream(:frames, [])
    |> assign(:streamed, MapSet.new())
    |> stream_frames()
  end

  defp stream_frames(%{assigns: %{id: id, frames: frames, streamed: streamed}} = socket) do
    list = Frames.list(frames)
    held = MapSet.new(list, & &1.id)

    streamed
    |> MapSet.difference(held)
    |> Enum.reduce(socket, &stream_delete_by_dom_id(&2, :frames, wrapper_id(id, &1)))
    |> stream(:frames, list)
    |> assign(:streamed, held)
  end

  defp wrapper_id(id, frame_id), do: "#{id}-frame-#{frame_id}"

  # The posture's arrangement, read under the caller's context. A read
  # that fails keeps what is drawn and marks the posture read, so the
  # next update does not read again; the next posture report does.
  defp load(socket) do
    %{context: ctx, posture: posture} = socket.assigns

    case Compendium.layout(ctx, posture) do
      {:ok, %{arrangement: arrangement} = read} ->
        send(self(), {__MODULE__, :layout, posture, read})
        assign(socket, read: arrangement, loaded: posture, layout_unavailable: false)

      {:error, _refusal} ->
        send(self(), {__MODULE__, :layout_unavailable})
        assign(socket, loaded: posture, layout_unavailable: true)
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    # The shell's arrangement, current with every gesture; before its first
    # read, this layer's own.
    arrangement = assigns.arrangement || assigns.read
    visible = Frames.visible_canvas(assigns.frames)
    active = active_app(assigns.frames, visible)

    assigns =
      assign(assigns,
        canvases: canvases(arrangement),
        visible: visible,
        active: active,
        boxes: boxes(assigns.frames),
        cards: Map.new(assigns.tinctures, &{&1.id, &1}),
        shelf: not is_nil(visible),
        shelf_apps: shelf_apps(assigns, arrangement, visible, active),
        # Under a shown full frame every other layer is covered, and taken
        # out of reach so no key lands on a control nobody can see.
        covering: covering(assigns.frames)
      )

    ~H"""
    <div id={@id} class="pointer-events-none absolute inset-0">
      <div id={"#{@id}-geometry"} phx-update="ignore"></div>
      <div id={"#{@id}-status"} phx-update="ignore">
        <div
          data-canvas-connection="connected"
          hidden
          class="absolute left-1/2 top-3 z-[69] -translate-x-1/2 rounded-full bg-black/70 px-3 py-1 text-xs text-white/90"
        >
          Disconnected. Reconnecting…
        </div>
      </div>

      <%!-- Every frame, in the order it was opened, as a stream: nothing
           before this container but the two elements above, which are
           always drawn. It fills the apps' area (the layer above the
           shelf), clips a window hanging past the area's edge so the page
           never scrolls for it (a full app is fixed, which it does not
           clip), and sets no z-index, so it adds no stacking context. The
           sandbox and allow attributes are the rules' derivation, never
           written here. In each wrapper the iframe comes first and the
           chrome after it, so a placement that adds or drops the chrome
           never moves the iframe. --%>
      <div
        id={"#{@id}-frames"}
        phx-update="stream"
        class={[
          "pointer-events-none absolute inset-x-0 top-0 overflow-hidden",
          if(@shelf, do: "bottom-[52px]", else: "bottom-0")
        ]}
      >
        <div
          :for={{wrapper_id, frame} <- @streams.frames}
          id={wrapper_id}
          data-canvas-frame={frame.id}
          data-canvas-place={place(frame)}
          data-canvas-stack={app_attribute(frame, :stack)}
          data-canvas-minimised={app_attribute(frame, :minimised)}
          data-canvas-geometry={geometry_attribute(frame.placement)}
          data-canvas-side={side_attribute(frame.placement)}
          data-canvas-share={share_attribute(frame.placement)}
          data-canvas-tile-share={tile_share_attribute(frame.placement)}
          data-canvas-window={window_attribute(frame.placement)}
          data-canvas-active={app_frame?(frame) && to_string(frame.id == @active)}
          data-canvas-shown={to_string(frame.visible)}
          inert={inert?(frame, @covering)}
          class={frame_class(frame, frame.id == @active)}
          style={Map.get(@boxes, frame.id)}
        >
          <iframe
            :if={frame.state != :refused}
            id={frame.id}
            src={frame.src}
            sandbox={frame.sandbox}
            allow={if frame.allow not in [nil, ""], do: frame.allow}
            class={iframe_class(frame)}
            phx-hook="IframeBridge"
            data-frame-id={frame.id}
            data-frame-state={frame.state}
            data-frame-kind={if Frames.canvas_key?(frame.key), do: "canvas"}
            inert={frame.state == :frozen or match?({:validation, _}, frame.key)}
          />
          <div
            :if={frame.state == :refused}
            id={"tincture_state_#{frame.id}"}
            data-tincture-state={frame.refusal}
            class={[
              "flex items-center justify-center p-4 text-center text-sm text-text-muted",
              if(chrome?(frame), do: "canvas-app-body", else: "h-full w-full")
            ]}
          >
            {refusal_sentence(frame.refusal)}
          </div>
          <.chrome :if={chrome?(frame)} frame={frame} card={Map.get(@cards, frame.tincture_id)} />
          <.iframe_capsule :if={frame.placement == :full} />
        </div>
      </div>

      <%!-- The `Canvas` hook, on an empty element of its own: the page locks
           the element an event is pushed from until its reply, and a locked
           element around the frames keeps a frame the layer discards while
           it waits. The hook reads the layer as this element's parent. --%>
      <div
        id={"#{@id}-hook"}
        phx-hook="Canvas"
        phx-target={@myself}
        data-posture={@posture}
      >
      </div>

      <p
        :if={@layout_unavailable}
        data-canvas-layout="unavailable"
        inert={@covering != nil}
        class="absolute bottom-16 left-3 z-[68] text-xs text-text-muted"
      >
        Your layout can't be read right now.
      </p>

      <%!-- The shelf is Prism's: no canvas draws or reaches it. Its left
           end leaves room for the shell's own chips, its right end for the
           AQUA button, which the app layout draws. --%>
      <nav
        :if={@shelf}
        id="canvas-shelf"
        aria-label="Canvases and open apps"
        class="canvas-shelf pointer-events-auto"
      >
        <div class="canvas-shelf-chips" aria-hidden="true"></div>
        <div :if={length(@canvases) > 1} id="canvas-switcher" role="group" aria-label="Canvases">
          <button
            :for={{canvas, index} <- Enum.with_index(@canvases, 1)}
            type="button"
            phx-click="switch_canvas"
            phx-value-canvas={canvas.id}
            data-canvas={canvas.id}
            aria-pressed={to_string(canvas.id == @visible)}
            aria-label={canvas.id}
            title={if index <= 8, do: "#{canvas.id} (Ctrl+Alt+#{index})", else: canvas.id}
            class="canvas-dot"
          ></button>
        </div>
        <div id="canvas-shelf-apps" role="group" aria-label="Open apps">
          <button
            :for={app <- @shelf_apps}
            type="button"
            phx-click={app.push}
            data-canvas-shelf-app={app.ref}
            data-canvas-active={to_string(app.active)}
            data-canvas-minimised={to_string(app.minimised)}
            aria-pressed={to_string(app.active)}
            title={app.title}
            class="canvas-shelf-app"
          >
            <span class="canvas-app-icon" aria-hidden="true">{app.icon}</span>
            <span class="truncate">{app.name}</span>
          </button>
        </div>
        <div class="canvas-shelf-aqua" aria-hidden="true"></div>
      </nav>
    </div>
    """
  end

  attr :frame, :map, required: true
  attr :card, :map, default: nil

  # The chrome the shell draws around an app's frame, outside it, so no app
  # draws or presses it: the title bar (drag it to move the window; the
  # hook reads `data-canvas-grip`), its four controls, and the edges a
  # window is resized from or the divider a tile is.
  defp chrome(assigns) do
    assigns =
      assign(assigns,
        name: app_name(assigns.card, assigns.frame),
        subtitle: app_subtitle(assigns.card),
        icon: app_icon(assigns.card, assigns.frame),
        tile?: match?({:tile, _, _}, assigns.frame.placement)
      )

    ~H"""
    <div class="canvas-titlebar" data-canvas-grip={@frame.id}>
      <span class="canvas-app-icon" aria-hidden="true">{@icon}</span>
      <span class="canvas-app-name">{@name}</span>
      <span :if={@subtitle} class="canvas-app-title" title={@subtitle}>{@subtitle}</span>
      <div class="canvas-controls" role="toolbar" aria-label={"#{@name} controls"}>
        <button
          type="button"
          class="canvas-ghost"
          data-canvas-action="minimise"
          phx-click={JS.push("frame_minimise", value: %{frame: @frame.id})}
          aria-label="Minimise"
          title="Minimise (Ctrl+Alt+M)"
        >
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 11h8" /></svg>
        </button>
        <button
          type="button"
          class="canvas-ghost"
          data-canvas-action={if @tile?, do: "window", else: "tile"}
          phx-click={toggle_push(@frame)}
          aria-label={if @tile?, do: "Make a window", else: "Tile at the side"}
          title={
            if @tile?,
              do: "Make a window (Ctrl+Alt+Down)",
              else: "Tile at the side (Ctrl+Alt+Left or Right)"
          }
        >
          <svg :if={not @tile?} viewBox="0 0 16 16" aria-hidden="true">
            <rect x="2.5" y="3.5" width="11" height="9" rx="1" /><path d="M8 3.5v9" />
          </svg>
          <svg :if={@tile?} viewBox="0 0 16 16" aria-hidden="true">
            <rect x="3.5" y="4.5" width="9" height="7" rx="1" />
          </svg>
        </button>
        <button
          type="button"
          class="canvas-ghost"
          data-canvas-action="full"
          phx-click={JS.push("frame_full", value: %{frame: @frame.id})}
          aria-label="Full screen"
          title="Full screen (Ctrl+Alt+Up)"
        >
          <svg viewBox="0 0 16 16" aria-hidden="true">
            <path d="M3 6V3h3M10 3h3v3M13 10v3h-3M6 13H3v-3" />
          </svg>
        </button>
        <button
          type="button"
          class="canvas-ghost canvas-ghost-close"
          data-canvas-action="close"
          phx-click={JS.push("frame_close", value: %{frame: @frame.id})}
          aria-label="Close"
          title="Close (Ctrl+Alt+W)"
        >
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></svg>
        </button>
      </div>
    </div>
    <div
      :for={edge <- edges(@frame.placement)}
      class={if @tile?, do: "canvas-divider", else: "canvas-edge"}
      data-canvas-edge={edge}
      aria-hidden="true"
    >
    </div>
    """
  end

  defp iframe_capsule(assigns) do
    ~H"""
    <div
      class="absolute right-4 top-4 z-30 flex items-center rounded-full border border-white/10 bg-black/55 shadow-lg backdrop-blur-md"
      role="toolbar"
      aria-label="Tincture controls"
    >
      <button
        class="flex h-8 w-10 items-center justify-center rounded-l-full text-text-secondary transition-colors hover:bg-white/5 hover:text-text-primary"
        title="More"
        aria-label="More options"
      >
        <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <circle cx="5" cy="12" r="1" fill="currentColor" />
          <circle cx="12" cy="12" r="1" fill="currentColor" />
          <circle cx="19" cy="12" r="1" fill="currentColor" />
        </svg>
      </button>
      <span class="h-4 w-px bg-white/15" aria-hidden="true"></span>
      <button
        phx-click="close_active_tincture"
        class="flex h-8 w-10 items-center justify-center rounded-r-full text-text-secondary transition-colors hover:bg-white/5 hover:text-text-primary"
        title="Close (Esc)"
        aria-label="Close tincture"
      >
        <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp canvases(arrangement) when is_list(arrangement), do: arrangement
  defp canvases(nil), do: []

  # The key of the shown full frame, which covers every other layer, or nil.
  defp covering(frames) do
    case Frames.active(frames) do
      %{key: key, visible: true} -> key
      _none -> nil
    end
  end

  # A validation frame is always out of reach; any other frame is while a
  # full frame covers it.
  defp inert?(%{key: {:validation, _}}, _covering), do: true
  defp inert?(%{key: key}, covering), do: covering not in [nil, key]

  defp place(%{key: {:canvas, _}}), do: "canvas"
  defp place(%{key: {:validation, _}}), do: "validation"
  defp place(%{placement: {:window, _}}), do: "window"
  defp place(%{placement: {:tile, _, _}}), do: "tile"
  defp place(%{placement: :full}), do: "full"

  defp app_attribute(%{key: {:app, _, _}} = frame, field), do: to_string(Map.fetch!(frame, field))
  defp app_attribute(_frame, _field), do: nil

  defp app_frame?(%{key: {:app, _, _}}), do: true
  defp app_frame?(_frame), do: false

  # A window or a tile carries the shell's chrome; a full app its capsule.
  defp chrome?(%{key: {:app, _, _}, placement: {:window, _}}), do: true
  defp chrome?(%{key: {:app, _, _}, placement: {:tile, _, _}}), do: true
  defp chrome?(_frame), do: false

  # The app the keys and the ring act on, by frame id: the topmost shown
  # app of the visible canvas, full or not.
  defp active_app(frames, canvas) do
    frames
    |> Frames.list()
    |> Enum.filter(&match?(%{key: {:app, ^canvas, _}, visible: true}, &1))
    |> Enum.max_by(&{&1.stack, &1.id}, fn -> nil end)
    |> then(&(&1 && &1.id))
  end

  # The visible canvas's apps on the shelf, in the order they were opened:
  # each held app (a click raises it, or restores it when minimised), then
  # each app the layout read holds minimised and no frame does (a click
  # restores it).
  defp shelf_apps(_assigns, _arrangement, nil, _active), do: []

  defp shelf_apps(assigns, arrangement, canvas, active) do
    cards = Map.new(assigns.tinctures, &{Frames.ref_of(&1), &1})

    held =
      for %{key: {:app, ^canvas, ref}} = frame <- Frames.list(assigns.frames) do
        push =
          if frame.minimised,
            do: JS.push("app_restore", value: %{ref: ref}),
            else: JS.push("frame_raise", value: %{frame: frame.id})

        shelf_entry(Map.get(cards, ref), ref, push, frame.id == active, frame.minimised)
      end

    held_refs = MapSet.new(held, & &1.ref)

    waiting =
      for %{id: ^canvas, apps: apps} <- canvases(arrangement),
          %{tincture: ref, minimised: true} <- apps,
          not MapSet.member?(held_refs, ref),
          card = Map.get(cards, ref),
          card != nil,
          do: shelf_entry(card, ref, JS.push("app_restore", value: %{ref: ref}), false, true)

    held ++ waiting
  end

  defp shelf_entry(card, ref, push, active, minimised) do
    name = app_name(card, nil) || ref

    %{
      ref: ref,
      name: name,
      icon: app_icon(card, nil),
      push: push,
      active: active,
      minimised: minimised,
      title: if(minimised, do: "#{name}, minimised: restore it", else: name)
    }
  end

  # What a person reads an app as: its name, as the canvas's launcher
  # names it.
  defp app_name(%{} = card, _frame), do: card.name
  defp app_name(nil, %{reference: %{name: name}}), do: name
  defp app_name(nil, _frame), do: nil

  # A title the app set (or its manifest's), shown after its name as
  # secondary text; nothing when it only repeats the name. The shelf shows
  # the name alone.
  defp app_subtitle(%{title: title, name: name}) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      ^name -> nil
      trimmed -> trimmed
    end
  end

  defp app_subtitle(_card), do: nil

  # Its manifest's emoji, or the first letter of its name.
  defp app_icon(%{icon_emoji: icon}, _frame) when is_binary(icon) and icon != "", do: icon

  defp app_icon(card, frame) do
    case app_name(card, frame) do
      name when is_binary(name) and name != "" -> name |> String.first() |> String.upcase()
      _none -> "·"
    end
  end

  # The tile or window control: a window becomes a tile at the side its
  # middle is on, a tile a window where it stood.
  defp toggle_push(%{id: id, placement: {:window, %{x: x, w: w}} = placement}) do
    side = if x + div(w, 2) < div(@max_fraction, 2), do: "left", else: "right"
    JS.push("frame_tile", value: %{frame: id, side: side, share: tile_share(placement)})
  end

  defp toggle_push(%{id: id, placement: placement}),
    do: JS.push("frame_move", value: %{frame: id, geometry: window_geometry(placement)})

  # The share a window takes as a tile: its own width, within reason.
  defp tile_share({:window, %{w: w}}), do: w |> max(2000) |> min(7000)

  # The geometry a tile or a full app takes as a window: a tile's where it
  # stood, a full app's in the middle.
  defp window_geometry({:tile, side, share}) do
    w = share |> max(3000) |> min(7000)
    x = if side == :left, do: 200, else: @max_fraction - w - 200
    %{x: x, y: 800, w: w, h: 7000}
  end

  defp window_geometry(_full), do: %{x: 1500, y: 1000, w: 7000, h: 7500}

  defp tile_share_attribute({:window, _} = placement),
    do: Integer.to_string(tile_share(placement))

  defp tile_share_attribute(_placement), do: nil

  defp window_attribute({:window, _}), do: nil

  defp window_attribute(placement) when placement == :full or is_tuple(placement) do
    %{x: x, y: y, w: w, h: h} = window_geometry(placement)
    "#{x} #{y} #{w} #{h}"
  end

  defp window_attribute(_placement), do: nil

  defp edges({:tile, :left, _share}), do: ["e"]
  defp edges({:tile, :right, _share}), do: ["w"]
  defp edges(_window), do: ~w(n s e w ne nw se sw)

  defp geometry_attribute({:window, %{x: x, y: y, w: w, h: h}}), do: "#{x} #{y} #{w} #{h}"
  defp geometry_attribute(_placement), do: nil

  defp side_attribute({:tile, side, _share}), do: Atom.to_string(side)
  defp side_attribute(_placement), do: nil

  defp share_attribute({:tile, _side, share}), do: Integer.to_string(share)
  defp share_attribute(_placement), do: nil

  defp frame_class(%{key: {:validation, _}}, _active), do: "hidden"

  # A canvas fills the layer under every app, narrowed by its tiles.
  defp frame_class(%{key: {:canvas, _}, visible: visible}, _active) do
    [
      "pointer-events-auto absolute inset-0 z-0 overflow-hidden bg-surface-base",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: :full, visible: visible}, _active) do
    [
      "pointer-events-auto fixed inset-0 z-[64] flex flex-col bg-surface-base",
      if(not visible, do: "hidden")
    ]
  end

  defp frame_class(%{placement: {:tile, _, _}, visible: visible}, active) do
    [
      "canvas-tile pointer-events-auto absolute overflow-hidden",
      active && "canvas-active",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: {:window, _}, visible: visible}, active) do
    [
      "canvas-window pointer-events-auto absolute overflow-hidden",
      active && "canvas-active",
      if(not visible, do: "invisible")
    ]
  end

  # Under the chrome's title bar, or filling the wrapper.
  defp iframe_class(frame),
    do: if(chrome?(frame), do: "canvas-app-body border-0", else: "h-full w-full border-0")

  # Where each frame stands, as CSS, by frame id: a window at its geometry
  # and a tile at its edge and share, and the visible canvas narrowed by the
  # tiles shown beside it. Tiles on one edge sit side by side in their
  # stacking order, left to right, at `z-index` 20. The windows shown are
  # stacked by their rank in that order, 30 for the lowest and one more for
  # each above it, whatever the layout's orders are, so raising an app
  # changes its style and never its place in the document.
  defp boxes(frames) do
    list = Frames.list(frames)
    canvas = Frames.visible_canvas(frames)

    ranks =
      list
      |> Enum.filter(&stacked?/1)
      |> Enum.sort_by(&{&1.stack, &1.id})
      |> Enum.with_index()
      |> Map.new(fn {frame, rank} -> {frame.id, rank} end)

    tiles =
      for %{key: {:app, ^canvas, _}, visible: true, placement: {:tile, _, _}} = frame <- list,
          do: frame

    {left, right} =
      Enum.split_with(Enum.sort_by(tiles, & &1.stack), &match?({:tile, :left, _}, &1.placement))

    left_total = left |> Enum.map(&share/1) |> Enum.sum() |> min(@max_fraction)
    right_total = right |> Enum.map(&share/1) |> Enum.sum() |> min(@max_fraction - left_total)

    tile_boxes =
      edge(left, 0) ++ edge(right, @max_fraction - right_total)

    Map.new(list, fn frame ->
      z = @window_z + Map.get(ranks, frame.id, 0)
      {frame.id, box(frame, tile_boxes, canvas, left_total, right_total, z)}
    end)
  end

  defp stacked?(%{key: {:app, _, _}, visible: true, placement: {:window, _}}), do: true
  defp stacked?(_frame), do: false

  defp share(%{placement: {:tile, _, share}}), do: share

  defp edge(tiles, from) do
    {boxes, _end} =
      Enum.map_reduce(tiles, from, fn frame, at ->
        width = min(share(frame), @max_fraction - at)
        {{frame.id, {at, width}}, at + width}
      end)

    boxes
  end

  defp box(%{key: {:canvas, id}}, _tiles, id, left, right, _z),
    do: "left: #{percent(left)}; right: #{percent(right)};"

  defp box(%{placement: {:window, %{x: x, y: y, w: w, h: h}}}, _tiles, _canvas, _l, _r, z),
    do:
      "left: #{percent(x)}; top: #{percent(y)}; width: #{percent(w)}; height: #{percent(h)}; " <>
        "z-index: #{z};"

  defp box(%{id: id, placement: {:tile, side, share}}, tiles, _canvas, _l, _r, _z) do
    {at, width} = List.keyfind(tiles, id, 0, {id, {fallback(side, share), share}}) |> elem(1)

    "top: 0; bottom: 0; left: #{percent(at)}; width: #{percent(width)}; z-index: #{@tile_z};"
  end

  defp box(_frame, _tiles, _canvas, _l, _r, _z), do: nil

  # A tile not shown keeps its own edge, at its own share.
  defp fallback(:left, _share), do: 0
  defp fallback(:right, share), do: @max_fraction - share

  defp percent(hundredths), do: :erlang.float_to_binary(hundredths / 100, decimals: 2) <> "%"

  defp refusal_sentence(:unavailable),
    do: "This tincture can't be opened right now. Try again shortly."

  defp refusal_sentence(:undeclared),
    do: "This tincture is not declared to open here, so it is not opened."

  defp refusal_sentence(:unregistered),
    do: "This tincture's version is not registered. Refresh the tinctures and try again."

  defp refusal_sentence(:ungranted),
    do: "This tincture asks for what you have not granted it yet, so it is not opened."

  defp refusal_sentence(:refused),
    do: "Your session can no longer open this tincture. Sign in again."
end
