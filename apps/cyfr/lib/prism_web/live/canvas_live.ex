# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLive do
  @moduledoc """
  The canvas layer: the person's layout read for the posture their client
  reports, and every frame the shell holds (`Prism.Frames`) drawn where its
  placement puts it.

  It reads the layout through `Compendium.layout/2` and draws, from the
  bottom: the visible canvas's frame filling the layer (a hidden canvas's
  frame is held invisible and frozen, and a validation frame is hidden and
  inert) and narrowed by the tiles beside it, its tiles at their edge and
  share, its windows at their geometry, and the active `full` frame above
  those, with its capsule. Geometry and shares are hundredths of a percent
  of the layer. The windows and tiles shown stack by their rank in the
  stacking order, as each wrapper's `z-index` from 30 up, under a full app
  at 50, which shows alone; raising an app restyles its wrapper and never
  moves it. Each app's wrapper carries what it stands as for the hook:
  `data-canvas-place` (`window`, `tile` or `full`), `data-canvas-stack`,
  `data-canvas-minimised`, and `data-canvas-geometry` (`x y w h`) or
  `data-canvas-side` and `data-canvas-share`. The assistant's panel
  (`PrismWeb.AquaPanelLive`), which the app layout draws over the page,
  sits above the windows and tiles. In safe mode (`safe_mode`) nothing of
  the layout is drawn. While a full frame is shown every other layer is `inert`, so no
  key reaches a control it covers; the full frame and its capsule stay
  reachable.

  With more than one canvas it draws the switcher (`#canvas-switcher`), one
  button per canvas carrying `data-canvas`, which asks the shell to show it
  (`switch_canvas` with `canvas`), and the edge strip (`#canvas-edge-strip`),
  16 pixels along the bottom edge above every frame, on which the `Canvas`
  hook reads a horizontal swipe. Neither is drawn in safe mode.

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
  (the shell's tincture cards) and `safe_mode`.

  The hook sits on an empty element of its own, `#<id>-hook`, after the
  frames, which carries `data-posture`; it reads the layer as that
  element's parent, and its pushes go from that element. It relays the
  shell's `frame_state`, `frame_credential` and `canvas_installed` pushes
  to each frame's bridge and sends each canvas frame its posture and what
  the shown apps cover of it. A canvas or validation frame carries
  `data-frame-kind="canvas"`, so its bridge hands it the canvas's
  handshake and forwards its messages as a canvas's.

  An iframe is never moved in the document, since a moved frame reloads:
  no patch removes or re-inserts a held frame's iframe or any element
  around it, and only that frame's own discard removes it. The page's
  patch moves an element when an earlier sibling is removed or one whose
  presence varies appears or disappears before it, so the frames' wrappers
  are a stream: the only children of one `phx-update="stream"` container,
  where a patch updates a child in place and never re-adds it. Every
  update streams each held frame, a wrapper already drawn patched where it
  stands and a new one appended, so frames keep the order they were opened
  in, and deletes the wrapper of each frame no longer held. In the layer
  the container follows only the geometry and status elements, which are
  always drawn; the hook's element, the layout note, the edge strip and
  the switcher follow it. The shell draws nothing whose
  presence varies before the layer.

  No element around the frames, up to the page's root, carries a hook or
  an event binding. The page locks the element an event is pushed from
  until its reply and patches a copy of it meanwhile; a wrapper deleted
  then is removed from the document but kept in the copy, which the reply
  puts back, and the discarded frame would load again.
  """

  use PrismWeb, :live_component

  alias Prism.Frames

  @postures Prima.Layout.postures()
  @max_fraction 10_000
  @app_z 30

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       posture: "desk",
       loaded: nil,
       arrangement: nil,
       layout_unavailable: false,
       frames: Frames.new(),
       streamed: nil,
       tinctures: [],
       safe_mode: false
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
        assign(socket, arrangement: arrangement, loaded: posture, layout_unavailable: false)

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
    # In safe mode nothing of the layout is drawn.
    arrangement = if assigns.safe_mode, do: nil, else: assigns.arrangement
    visible = Frames.visible_canvas(assigns.frames)

    assigns =
      assign(assigns,
        canvases: canvases(arrangement),
        visible: visible,
        boxes: boxes(assigns.frames),
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
          class="absolute left-1/2 top-3 z-[60] -translate-x-1/2 rounded-full bg-black/70 px-3 py-1 text-xs text-white/90"
        >
          Disconnected. Reconnecting…
        </div>
      </div>

      <%!-- Every frame, in the order it was opened, as a stream: nothing
           before this container but the two elements above, which are
           always drawn. It fills the layer as the layer does and sets no
           z-index, so it adds no geometry and no stacking context. The
           sandbox and allow attributes are the rules' derivation, never
           written here. --%>
      <div id={"#{@id}-frames"} phx-update="stream" class="pointer-events-none absolute inset-0">
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
          data-canvas-shown={to_string(frame.visible)}
          inert={inert?(frame, @covering)}
          class={frame_class(frame)}
          style={Map.get(@boxes, frame.id)}
        >
          <iframe
            :if={frame.state != :refused}
            id={frame.id}
            src={frame.src}
            sandbox={frame.sandbox}
            allow={if frame.allow not in [nil, ""], do: frame.allow}
            class="h-full w-full border-0"
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
            class="flex h-full w-full items-center justify-center p-4 text-center text-sm text-text-muted"
          >
            {refusal_sentence(frame.refusal)}
          </div>
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
        class="absolute bottom-3 left-3 z-20 text-xs text-text-muted"
      >
        Your layout can't be read right now.
      </p>

      <%!-- The edge strip and the switcher are Prism's: no canvas draws or
           reaches them. --%>
      <div
        :if={length(@canvases) > 1}
        id="canvas-edge-strip"
        aria-hidden="true"
        class="pointer-events-auto absolute inset-x-0 bottom-0 z-[51] h-4 touch-none"
      >
      </div>

      <nav
        :if={length(@canvases) > 1}
        id="canvas-switcher"
        aria-label="Canvases"
        class="pointer-events-auto absolute bottom-2 left-1/2 z-[55] flex -translate-x-1/2 items-center gap-1 rounded-full bg-black/60 px-2 py-1"
      >
        <button
          :for={canvas <- @canvases}
          type="button"
          phx-click="switch_canvas"
          phx-value-canvas={canvas.id}
          data-canvas={canvas.id}
          aria-pressed={to_string(canvas.id == @visible)}
          class={[
            "min-h-6 rounded-full px-2 text-xs focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-300",
            if(canvas.id == @visible,
              do: "bg-white/20 text-white",
              else: "text-white/70 hover:text-white"
            )
          ]}
        >
          {canvas.id}
        </button>
      </nav>
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

  defp geometry_attribute({:window, %{x: x, y: y, w: w, h: h}}), do: "#{x} #{y} #{w} #{h}"
  defp geometry_attribute(_placement), do: nil

  defp side_attribute({:tile, side, _share}), do: Atom.to_string(side)
  defp side_attribute(_placement), do: nil

  defp share_attribute({:tile, _side, share}), do: Integer.to_string(share)
  defp share_attribute(_placement), do: nil

  defp frame_class(%{key: {:validation, _}}), do: "hidden"

  # A canvas fills the layer under every app, narrowed by its tiles.
  defp frame_class(%{key: {:canvas, _}, visible: visible}) do
    [
      "pointer-events-auto absolute inset-0 z-0 overflow-hidden bg-surface-base",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: :full, visible: visible}) do
    [
      "pointer-events-auto fixed inset-0 z-50 flex flex-col bg-surface-base",
      if(not visible, do: "hidden")
    ]
  end

  defp frame_class(%{placement: {:tile, _, _}, visible: visible}) do
    [
      "pointer-events-auto absolute overflow-hidden bg-surface-raised ring-1 ring-white/10",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: {:window, _}, visible: visible}) do
    [
      "pointer-events-auto absolute overflow-hidden rounded-xl bg-surface-raised shadow-2xl ring-1 ring-white/10",
      if(not visible, do: "invisible")
    ]
  end

  # Where each frame stands, as CSS, by frame id: a window at its geometry
  # and a tile at its edge and share, and the visible canvas narrowed by the
  # tiles shown beside it. Tiles on one edge sit side by side in their
  # stacking order, left to right. The windows and tiles shown are stacked
  # by their rank in that order, `z-index` 30 for the lowest and one more
  # for each above it, whatever the layout's orders are, so raising an app
  # changes its style and never its place in the document; a full app is at
  # 50, and shown it is alone.
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
      z = @app_z + Map.get(ranks, frame.id, 0)
      {frame.id, box(frame, tile_boxes, canvas, left_total, right_total, z)}
    end)
  end

  defp stacked?(%{key: {:app, _, _}, visible: true, placement: {:window, _}}), do: true
  defp stacked?(%{key: {:app, _, _}, visible: true, placement: {:tile, _, _}}), do: true
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

  defp box(%{id: id, placement: {:tile, side, share}}, tiles, _canvas, _l, _r, z) do
    {at, width} = List.keyfind(tiles, id, 0, {id, {fallback(side, share), share}}) |> elem(1)

    "top: 0; bottom: 0; left: #{percent(at)}; width: #{percent(width)}; z-index: #{z};"
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
