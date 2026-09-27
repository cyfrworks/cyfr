# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLive do
  @moduledoc """
  The canvas: the person's layout drawn for the posture their client
  reports, and every frame the shell holds (`Prism.Frames`) where its
  placement puts it.

  It reads the layout through `Compendium.layout/2` and draws the
  posture's arrangement (`Prima.Layout`): the desktop frame filling the
  canvas at the bottom, the slots in order with their size classes above
  it, the floating layers above them, and the active `:full` frame above
  those. A `full` slot is its tincture's own frame. While a desktop frame
  is held the desktop draws the `icon` and `card` slots itself; without
  one they are tiles that launch their tincture. An entry naming a
  tincture that is not installed draws a placeholder and opens nothing.
  In safe mode (`safe_mode`) nothing of the layout is drawn.

  The posture is the client's: the `Canvas` hook (`assets/js/canvas/`)
  reports `hand` or `desk` as the event `posture`, and any other value is
  ignored. Before the first report the canvas draws `desk`. Each
  arrangement read is sent to the shell as
  `{PrismWeb.CanvasLive, :arrangement, arrangement}`, and the shell opens
  and discards frames for it (`Prism.Frames.arrange/4`); a read that
  fails is sent as `{PrismWeb.CanvasLive, :layout_unavailable}`. The
  canvas itself opens no frame and holds no credential. An update with
  `reload: true` reads the layout again.

  Assigns: `context`, `frames` (the shell's `Prism.Frames`), `tinctures`
  (the shell's tincture cards) and `safe_mode`.

  The hook computes the slots' geometry from the slot list rendered in
  `data-slots`, relays the shell's `frame_state` signals to each frame's
  bridge, and keeps the last arrangement drawn while the socket is down.
  An iframe is never moved in the document, since a moved frame reloads:
  frames render in the order they were opened, and a slot frame takes its
  slot's geometry by `data-canvas-place`.
  """

  use PrismWeb, :live_component

  alias Prism.Frames

  @postures Prima.Layout.postures()

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       posture: "desk",
       loaded: nil,
       arrangement: nil,
       layout_unavailable: false,
       frames: Frames.new(),
       tinctures: [],
       safe_mode: false
     )}
  end

  @impl true
  def update(%{reload: true} = assigns, socket) do
    update(Map.delete(assigns, :reload), assign(socket, :loaded, nil))
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

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

  # The posture's arrangement, read under the caller's context. A read
  # that fails keeps what is drawn and marks the posture read, so the
  # next update does not read again; the next posture report does.
  defp load(socket) do
    %{context: ctx, posture: posture} = socket.assigns

    case Compendium.layout(ctx, posture) do
      {:ok, %{arrangement: arrangement}} ->
        send(self(), {__MODULE__, :arrangement, arrangement})
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
    # In safe mode nothing of the layout is drawn. A desktop draws the icon
    # and card slots itself, so while one is held the canvas draws only
    # the full slots it has not framed yet.
    arrangement = if assigns.safe_mode, do: nil, else: assigns.arrangement
    desktop? = Frames.desktop(assigns.frames) != nil

    assigns =
      assign(assigns,
        slots: slots(arrangement),
        tiles: Enum.reject(slots(arrangement), &(desktop? and &1.size != :full)),
        floating: floating(arrangement),
        list: Frames.list(assigns.frames)
      )

    ~H"""
    <div
      id={@id}
      phx-hook="Canvas"
      phx-target={@myself}
      data-posture={@posture}
      data-slots={slot_json(@slots)}
      class="pointer-events-none absolute inset-0"
    >
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

      <p
        :if={@layout_unavailable}
        data-canvas-layout="unavailable"
        class="absolute bottom-3 left-3 z-20 text-xs text-text-muted"
      >
        Your layout can't be read right now.
      </p>

      <%!-- The apps layer: icon and card tiles, placeholders, and full slots
           whose frame is not open yet. --%>
      <%= for slot <- @tiles, not framed?(@frames, slot) do %>
        <.slot_tile slot={slot} card={Frames.resolve(slot.tincture, @tinctures)} />
      <% end %>

      <%!-- Floating tinctures nobody installed. --%>
      <%= for {entry, index} <- Enum.with_index(@floating),
              is_nil(Frames.resolve(entry.tincture, @tinctures)) do %>
        <div
          id={"#{@id}-float-#{index}"}
          data-canvas-placeholder={entry.tincture}
          class="pointer-events-auto absolute z-30 flex items-center justify-center rounded-xl border border-dashed border-border-default bg-surface-raised/80 p-3 text-center text-xs text-text-muted"
          style={float_style(entry.position)}
        >
          Not installed: {entry.tincture}
        </div>
      <% end %>

      <%!-- Every frame, in the order it was opened. The sandbox and allow
           attributes are the rules' derivation for the frame's declared
           capabilities, never written here. --%>
      <%= for frame <- @list do %>
        <div
          id={"#{@id}-frame-#{frame.id}"}
          data-canvas-frame={frame.id}
          data-canvas-place={place(frame.placement)}
          class={frame_class(frame)}
          style={frame_style(frame.placement)}
        >
          <iframe
            :if={frame.state != :refused}
            id={frame.id}
            src={frame.src}
            sandbox={frame.sandbox}
            allow={if frame.allow != "", do: frame.allow}
            class="h-full w-full border-0"
            phx-hook="IframeBridge"
            data-frame-id={frame.id}
            data-frame-state={frame.state}
            inert={frame.state == :frozen}
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
      <% end %>
    </div>
    """
  end

  attr :slot, :map, required: true
  attr :card, :map, default: nil

  defp slot_tile(%{card: nil} = assigns) do
    ~H"""
    <div
      data-canvas-place={"slot:" <> @slot.id}
      data-canvas-placeholder={@slot.tincture}
      class={[
        "canvas-slot canvas-slot--#{@slot.size}",
        "pointer-events-auto absolute z-20 flex items-center justify-center rounded-xl border border-dashed border-border-default bg-surface-raised/80 p-2 text-center text-[11px] text-text-muted"
      ]}
    >
      Not installed: {@slot.tincture}
    </div>
    """
  end

  defp slot_tile(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_tincture"
      phx-value-tincture={@card.id}
      data-canvas-place={"slot:" <> @slot.id}
      data-canvas-tincture={@slot.tincture}
      class={[
        "canvas-slot canvas-slot--#{@slot.size}",
        "pointer-events-auto absolute z-20 flex flex-col items-center justify-center gap-1 overflow-hidden rounded-xl bg-surface-raised/90 p-2 text-center ring-1 ring-white/10 transition-colors hover:ring-accent-primary/60"
      ]}
    >
      <span class="text-lg font-semibold text-text-secondary">{initial(@card)}</span>
      <span class="w-full truncate text-[11px] text-text-muted">{@card.title || @card.name}</span>
      <span :if={@slot.size == :card and @slot.card} class="text-[10px] text-text-muted/70">
        {@slot.card}
      </span>
    </button>
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

  defp slots(%{slots: slots}), do: slots
  defp slots(nil), do: []

  defp floating(%{floating: floating}), do: floating
  defp floating(nil), do: []

  defp framed?(frames, %{size: :full, id: id}), do: Frames.get(frames, {:slot, id}) != nil
  defp framed?(_frames, _slot), do: false

  # What the hook lays out: each slot's id, size and order, in order.
  defp slot_json(slots) do
    slots
    |> Enum.map(&%{id: &1.id, size: &1.size, order: &1.order})
    |> Jason.encode!()
  end

  defp place({:slot, id}), do: "slot:" <> id
  defp place({:floating, _position}), do: "float"
  defp place(:full), do: "full"
  defp place(:desktop), do: "desktop"

  defp frame_class(%{placement: :full, visible: visible}) do
    [
      "pointer-events-auto fixed inset-0 z-50 flex flex-col bg-surface-base",
      if(not visible, do: "hidden")
    ]
  end

  # The desktop fills the canvas under every slot and floating layer.
  defp frame_class(%{placement: :desktop, visible: visible}) do
    [
      "pointer-events-auto absolute inset-0 z-0 overflow-hidden bg-surface-base",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: {:slot, _}, visible: visible}) do
    [
      "pointer-events-auto absolute z-20 overflow-hidden rounded-xl bg-surface-raised ring-1 ring-white/10",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_class(%{placement: {:floating, _}, visible: visible}) do
    [
      "pointer-events-auto absolute z-30 overflow-hidden rounded-xl bg-surface-raised shadow-2xl ring-1 ring-white/10",
      if(not visible, do: "invisible")
    ]
  end

  defp frame_style({:floating, position}), do: float_style(position)
  defp frame_style(_placement), do: nil

  # A floating layer sits at its layout position, in hundredths of a
  # percent of the canvas, and is kept inside the canvas.
  @float_width "min(22rem, 100%)"
  @float_height "min(15rem, 100%)"

  defp float_style(%{x: x, y: y}) do
    "left: min(#{percent(x)}, calc(100% - #{@float_width})); " <>
      "top: min(#{percent(y)}, calc(100% - #{@float_height})); " <>
      "width: #{@float_width}; height: #{@float_height};"
  end

  defp percent(hundredths), do: :erlang.float_to_binary(hundredths / 100, decimals: 2) <> "%"

  defp initial(%{title: title, name: name}) do
    str = if title && title != "", do: title, else: name

    case str |> String.trim() |> String.first() do
      nil -> "?"
      ch -> String.upcase(ch)
    end
  end

  defp refusal_sentence(:unavailable),
    do: "This tincture can't be opened right now. Try again shortly."

  defp refusal_sentence(:undeclared),
    do: "This tincture asks for a frame capability it does not declare, so it is not opened."

  defp refusal_sentence(:unregistered),
    do: "This tincture's version is not registered. Refresh the tinctures and try again."

  defp refusal_sentence(:ungranted),
    do: "This tincture asks for what you have not granted it yet, so it is not opened."

  defp refusal_sentence(:refused),
    do: "Your session can no longer open this tincture. Sign in again."
end
