# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  @gesture_events ~w(frame_move frame_resize frame_tile frame_full frame_minimise frame_raise
                     frame_close app_open app_restore)

  # How long after the first gesture not yet written the layout is
  # written: every gesture made meanwhile folds into that one write.
  @write_after_ms 500
  @write_retry_ms 5_000
  @write_retries 5
  @conflict_replays 3
  # The writes a page's end makes of the gestures still waiting
  # (`flush_layout/1`): the first, and one more after a newer revision.
  @flush_writes 2

  @moduledoc """
  The Prism shell: the person's canvases, the tinctures opened over them,
  the system layer and, when no canvas runs, the tincture picker. It is the
  Canvas mode, at `/a/<athanor>/canvas`, filling the screen under the top
  bar with no sidebar or drawer; every other page is the Dashboard, and the
  top bar switches between them (`PrismWeb.TopbarLive`).

  Switching modes is a page navigation, so the shell's frames end with the
  page: `terminate/2` writes any gesture still waiting to be written (once
  more on the newer layout when another screen published one meanwhile),
  then revokes every credential it minted, and an app open over a canvas
  starts over when the person comes back. Nothing of the arrangement is lost: the
  layout holds every app's placement, and the shell opens the apps from it
  again on return.

  ## The canvases

  The shell shows one of the canvases the person's layout names for the
  posture (`Compendium.layout/2`; a person who never arranged one has the
  shipped canvas, `home` on `tincture:local.canvas`): the visible canvas,
  the layout's first at mount (`Prism.Frames.visible_canvas/1`). It opens
  that canvas's working version (`Compendium.canvas_versions/2`) as a frame
  keyed `{:canvas, id}`, and holds the apps the layout places over it,
  each as a window, a tile or full (`Prism.Frames.arrange/5`). A canvas whose newest installed
  version is not its working version, its kept version or its recorded
  failure is validated first (`Prism.CanvasValidation`): only `ready`
  activates it. When a validation ends, the shell compares again: a newer
  version written meanwhile that needs validating is validated in its
  turn, each such version once, and otherwise the working version opens.
  A grant prompt the shell raised for a canvas is withdrawn once the
  canvas is decided for another tincture, leaves the screen or falls
  back. The shell
  reads its listing (`Prism.TinctureRegistry`) again each time it decides
  a canvas with no frame held, and decides against that one read, so a
  tincture, a canvas or a version installed or removed while the shell is
  open is decided as the registry lists it now. A canvas
  whose tincture is not installed is not shown, and validates nothing; its
  apps still open, and the picker is drawn. A
  layout published anywhere for this person (`Cyfr.Bus.LayoutPublished` on
  their own topic) is read again, and the frames follow it.

  The person switches canvases with the switcher, `Ctrl+Alt+ArrowLeft` and
  `Ctrl+Alt+ArrowRight`, or a horizontal swipe on the canvas's edge strip,
  each sent as `switch_canvas`, with no wrap at either end; no canvas
  switches itself. A switch freezes the canvas it leaves, whatever it
  declares, and its apps unless they hold a background grant; a canvas
  once opened stays held until the shell ends, the layout drops it or it
  falls back, and showing it again thaws it.

  A canvas frame is a page like any tincture's: its messages over the
  port its bridge hands it are the shell verbs of `Prima.TinctureWire`,
  as `frame_verb`. Its handshake hands it its bearer and its `canvas`
  block (`Prima.TinctureWire.canvas_handshake/4`); `installed` (every
  listed tincture that is not a canvas, by name) is pushed to each held
  canvas frame after its handshake and whenever the listing changes, and
  `posture`, `covered` and `state` come from the glass. From the live,
  visible canvas, `ready` keeps it standing, `failed` before `ready`
  falls it back (below), `open` is the person's open of a listed
  tincture (`app_open` below), `press` presses a feed's action through
  `feed.press` once the served version's declaration reads that feed, and
  `grant` offers the person's grant to an installed component through the
  system layer's generic grant path, unless an offer for it is open or it
  is granted already; its outcome opens no frame.
  `ready` and `failed` report how a canvas's page loaded and runs, so they
  count from a hidden canvas too, frozen or not the one shown: its `ready`
  makes it ready, and its `failed` before that marks it died, which falls
  it back once the canvas is shown. A `failed` from a canvas
  this view recorded as ready, shown or hidden, changes nothing: a page
  error after `ready` is not a crash. From a validation frame only `ready` and `failed`
  act. A canvas's other verbs, an `open`, a `press` or a `grant` from a
  canvas the glass does not show live, and `press` and `failed` from a frame that is
  not a canvas's are dropped and counted.

  ## Arranging

  The canvas hook sends one event per gesture, once the gesture settles:
  the end of a drag or a resize, never while it runs, or one press of a
  control or a key. Each names the frame the shell handed the app
  (`frame`) or a listed tincture (`ref`):

  | event | payload | the app |
  |---|---|---|
  | `frame_move` | `frame`, `geometry` | stands as a window at `geometry` |
  | `frame_resize` | `frame`, `geometry` or `share` | a window takes `geometry`, a tile `share` |
  | `frame_tile` | `frame`, `side`, `share` | stands as a tile at `side` |
  | `frame_full` | `frame` | takes the whole area |
  | `frame_minimise` | `frame` | leaves the screen, keeping its place |
  | `frame_raise` | `frame` | goes above every other |
  | `frame_close` | `frame` | leaves the canvas |
  | `app_restore` | `ref` | a minimised app comes back, raised |
  | `app_open` | `ref` | opens where the layout places it, or as `Prism.Arrangement.open/4` places it, raised |

  `geometry` is `{x, y, w, h}` and `share` a whole number, in hundredths
  of a percent of the canvas, `side` is `left` or `right`, each within the
  layout's bounds (`Prima.Layout`): `x` and `y` from 0 and `w`, `h` and
  `share` from 1, each to 10000. An event is answered `%{ok: true}`, or
  `%{error: reason}` with nothing changed: a frame this view does not
  hold (`not_held`), an app of a canvas not shown (`hidden`), a canvas
  behind a launch from the picker (`hidden`), a payload of another shape
  (`malformed`), a placement in the hand, where every app is full
  (`hand`), an app the layout does not place (`not_placed`) or a document
  the layout refuses (`invalid`). A gesture
  is made at once on the frames, keeping every frame still placed, and
  on the person's layout as this view holds it (`Prism.Arrangement`), and
  `installed` is pushed again to every canvas frame.

  The layout is written whole through the layout tool's `edit`, as the
  person (`PrismWeb.Ops`), over the revision this view last read or
  wrote: 500 ms after the first gesture not yet written, with every
  gesture made meanwhile folded into that one write. A write refused for
  a newer revision reads the layout again, makes the gestures that waited
  on it again, each that still applies, and writes again, up to three
  times; a write the store cannot answer is tried again every five
  seconds, up to five times, the frames left as they are. A layout read
  while gestures wait to be written leaves the view as it is; a read of
  the revision this view last read or wrote, its own write announced
  among them, changes nothing; any other read is taken whole.

  ## The fallback

  A canvas the glass shows that has not sent `ready` within ten seconds of
  being shown — its frame's open, for one that opens shown — that sent
  `failed` before it, or that could not be opened, falls back
  (`Prism.Fallback`, `not_ready`); so does one whose frame dies while the
  glass shows it (`gone`: the page loaded a second time), a hidden canvas
  that failed before its `ready`, once it is shown (a hidden canvas whose
  frame dies is discarded, and opens anew once shown), and a canvas whose
  new version did not start and which has no earlier version to show
  (`not_validated`). A hidden canvas runs no ready deadline, since it
  reads and acts on nothing: one not ready yet has the whole ten seconds
  from the moment it is shown, and one ready before it was hidden stays
  ready.

  Falling back discards that canvas's frame, and a validation of it, with
  their credentials, withdraws a grant prompt it raised, and opens the
  shipped canvas (`tincture:local.canvas`) in its place on this glass,
  with no validation and no write. Every app over it, every other canvas
  and the assistant's panel stay as they are, and the person goes on
  arranging. While the glass shows it, the system layer draws one line in
  the shelf's area offering to try again and, while the canvas keeps one,
  the last working version. A canvas fallen back stays so: its late
  `ready` changes nothing, and the shipped canvas dying in turn is torn
  down with its credential and not opened again until the person tries
  again, the line standing. The
  fallback ends only on the person's choice — the canvas opened again
  from the layout, the kept version once the system layer restored it —
  or when a published layout names another tincture for the canvas or
  drops it; a publication that only arranges keeps it, so saving a
  gesture never opens the failed canvas again.

  ## The picker

  The picker is preview-first: a large 16:9 preview stage with vertical
  capsule navigation, a compact info bar and keyboard navigation (←/→
  tinctures, ↑/↓ previews, Enter launches). It is drawn when no canvas
  runs: a layout with no canvas, a canvas whose tincture is not installed,
  or a layout that could not be read. Launching a tincture opens its frame
  as the active full frame above everything the canvas draws; closing it,
  from inside the tincture or through its capsule, shows the next open one
  or returns to the canvas.

  ## Prompts

  A frame never asks for a secret. Its `credential` verb, honoured only
  for a live, visible frame whose version declares `vault.create`, sends
  the system layer a credential-entry prompt; when the prompt closes the
  frame is told, through `frame_credential` and its bridge, whether an
  entry was saved and nothing else. A frame refused because the person
  has not granted what its tincture declares now is offered the grant
  prompt, built from the consent walk's own plan and preview, and opened
  again once it is confirmed. The shell's `Devices` control opens the
  pairing prompt, where the person pairs or revokes a device.

  ## Frames

  The shell holds its frames as a `Prism.Frames` value in its assigns:
  that module opens, places, freezes, discards and attributes every
  frame, and reaches each frame credential only through
  `Sanctum.TinctureAuth`. The canvas (`PrismWeb.CanvasLive`) draws them,
  and sends the shell each arrangement of the person's layout it reads;
  the shell holds the frames that arrangement places. It is the shell's
  first element and the picker its last, so nothing whose presence varies
  is drawn before the canvas layer, and drawing or hiding the picker moves
  no element: no patch of the page reloads a frame the canvas holds or
  takes the system layer's open dialog out of the top layer. No element
  around the frames pushes an event, since the page locks the element an
  event is pushed from until its reply, and a patch made meanwhile would
  bring back a frame the layer discarded: the shell's keys (`keynav`) are
  heard on `#shell-keys`, an empty element of their own. The system layer
  (`PrismWeb.SystemLayer`) is mounted above them.

  The `IframeBridge` hook hands a frame a `MessagePort` on its first load,
  and the frame credential over that port only (`frame_handshake`,
  answered once per frame). The frame's SDK sends data to the endpoint
  under that bearer; the port carries the shell verbs of
  `Prima.TinctureWire`, which reach this view as `frame_verb`. A message
  that does not decode, that names a frame this view does not hold live
  (a frozen canvas's `ready` and `failed` excepted), or that asks for what
  its frame may not, is dropped and counted; no
  verb places, sizes or raises a frame. When a frame freezes or goes live
  again the view pushes `frame_state`, which the canvas hook relays to the
  frame's bridge.

  A live frame that is not a validation's, a shown canvas's included, has
  its credential renewed before its deadline while this view holds it
  (`Prism.Frames.renew/4`), and a frame that is not a canvas's is resumed
  under a new bearer when it is shown again: the view pushes each new
  bearer as `frame_bearer`, which the canvas hook relays to that frame's
  bridge alone, and keeps none. A frozen frame is not renewed, so a canvas
  hidden past its deadline is refused when it is shown again.

  A full frame fills the apps' area between the top bar and the shelf, and
  the canvas makes every layer under it `inert`. The top bar, the shelf,
  the full frame and its capsule, the system layer and the assistant's
  panel stay reachable.

  Activation, a press and the system layer's restore run in this view's
  own callbacks; it starts no task for them. Every credential this view
  minted is revoked on each path that ends it: `terminate/2` (the socket
  closed, the person navigated away, the view redirected) and the
  archived-athanor notice before it redirects. A new socket is a new open:
  nothing minted under an earlier one carries over.
  """

  require Logger

  alias Prism.CanvasValidation
  alias Prism.Frames
  alias Prism.Fallback
  alias Sanctum.TinctureAuth

  # How long a canvas has, from the moment the glass shows it, to send
  # `ready` before the shell falls it back (`ready_deadlines/2`): from
  # its frame's open, for one that opens shown, so a page that never
  # loads, and so never handshakes, falls back as one that loads
  # and dies.
  @canvas_ready_ms 10_000

  # The stream a canvas reads a feed's results on (`Opus.Providers.Feed`).
  @feed_stream "feed.results"

  # A frame credential is renewed this long before its deadline, or at
  # half its life when that life is shorter than twice this; never sooner
  # than the retry interval after it was armed.
  @renew_ahead_ms 300_000

  # How often a renewal the store or the member could not answer is tried
  # again, while the deadline is further away than this.
  @renew_retry_ms 30_000

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Canvas")
      |> assign(:active_nav, "canvas")
      |> assign(:frames, Frames.new())
      |> assign(:renewals, %{})
      |> assign(:posture, "desk")
      |> assign(:arrangement, nil)
      |> assign(:layout_base, nil)
      |> assign(:document, nil)
      |> assign(:pending, [])
      |> assign(:write_timer, nil)
      |> assign(:write_retries, 0)
      |> assign(:told, %{})
      |> assign(:showing, :pending)
      |> assign(:canvas_ready, MapSet.new())
      |> assign(:canvas_died, MapSet.new())
      |> assign(:canvas_deadlines, %{})
      |> assign(:layout_changed, false)
      |> assign(:decisions, %{})
      |> assign(:trialled, %{})
      |> assign(:fallbacks, %{})
      |> assign(:noticed, nil)
      |> assign(:spent, MapSet.new())
      |> assign(:credential_prompts, %{})
      |> assign(:grant_prompts, %{})
      |> assign(:grant_decisions, %{})
      |> assign(:pairing_prompt, nil)
      |> assign(:prompt_seq, 0)
      |> assign(:tinctures, [])
      |> assign(:canvases, [])
      |> assign(:focused_index, 0)
      |> assign(:current_preview_index, 0)

    socket =
      if connected?(socket) do
        # Subscribe to archive notifications so the shell stops using
        # a context whose athanor is no longer active, and to the person's
        # own layout topic so a layout published anywhere is read again.
        ctx = socket.assigns.context

        if ctx.athanor_id do
          actor = Sanctum.Context.actor(ctx)
          Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))

          if Prima.PersonId.person?(ctx.user_id),
            do: Cyfr.Bus.subscribe(actor, Cyfr.Bus.layouts(actor, ctx.user_id))
        end

        load_tinctures(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Re-read the registry CACHE on navigation (cheap — the registry
    # follows the tinctures topic for real changes), so a change that
    # broadcast while another page was open shows without a manual refresh.
    socket = if connected?(socket), do: load_tinctures(socket), else: socket
    {:noreply, focus_named(socket, params["publisher"], params["tincture_name"])}
  end

  # `ui.tincture.focus` navigates here with `?publisher=&tincture_name=`.
  # The picker is index-addressed, so the pair is resolved against the list
  # that was just loaded; a pair matching nothing leaves the current
  # selection alone rather than snapping the person to the first card.
  defp focus_named(socket, publisher, name) when is_binary(publisher) and is_binary(name) do
    case Enum.find_index(
           socket.assigns.tinctures,
           &(&1.publisher == publisher and &1.name == name)
         ) do
      nil -> socket
      idx -> focus_tincture(socket, idx)
    end
  end

  defp focus_named(socket, _publisher, _name), do: socket

  # ============================================================================
  # Picker navigation events
  # ============================================================================

  @impl true
  def handle_event("focus_tincture", %{"index" => idx_str}, socket) do
    case Integer.parse(to_string(idx_str)) do
      {idx, _} -> {:noreply, focus_tincture(socket, idx)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("next_preview", _params, socket) do
    {:noreply, cycle_preview(socket, +1)}
  end

  def handle_event("prev_preview", _params, socket) do
    {:noreply, cycle_preview(socket, -1)}
  end

  # A key typed into a prompt the shell opened is the prompt's: it moves
  # no picker and closes no frame.
  def handle_event("keynav", %{"key" => key}, socket) do
    if prompting?(socket.assigns),
      do: {:noreply, socket},
      else: {:noreply, handle_keynav(socket, key)}
  end

  def handle_event("close_active_tincture", _params, socket) do
    {:noreply, close_active_tincture(socket)}
  end

  # Shell events

  def handle_event("select_tincture", %{"tincture" => tincture_id}, socket) do
    if Enum.any?(socket.assigns.tinctures, &(&1.id == tincture_id)) do
      {:noreply, launch_tincture(socket, tincture_id)}
    else
      {:noreply, socket}
    end
  end

  # The scan walks the athanor's whole components tree and writes registry
  # rows — off the LiveView process, one at a time per athanor. A click
  # while a scan runs rides the running one instead of stacking another.
  def handle_event("refresh_tinctures", _params, socket) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    lv = self()
    scan_key = Arca.Cache.Keys.tincture_scan_running(Sanctum.Context.actor(ctx))

    case Arca.Cache.get(scan_key) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "A refresh is already running")}

      :miss ->
        Arca.Cache.put(scan_key, true, :timer.seconds(60))
        logger_metadata = Prima.LoggerContext.capture()

        Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
          Prima.LoggerContext.restore(logger_metadata)

          try do
            # Through the tool surface, like ComponentsLive's register
            # button — the scan writes registry rows, and the seam
            # (ToolSeamTest) holds every console mutation to the same
            # gates and audit row an agent's would get.
            call_tool(ctx, "component", %{"action" => "register"})
            Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
          after
            Arca.Cache.delete_match(scan_key)
          end

          send(lv, {:deliver, tag, :tinctures_refreshed})
        end)

        {:noreply, put_flash(socket, :info, "Refreshing tinctures…")}
    end
  end

  def handle_event("copy_url", %{"tincture" => tincture_id}, socket) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id))

    if tincture do
      # The public address: the home's own origin (`Sanctum.origin/0`) plus
      # the tincture's path.
      url =
        Cyfr.RuntimeConfig.origin() <>
          Prima.TinctureUrl.path(tincture.athanor_segment, tincture.publisher, tincture.name)

      {:noreply,
       socket
       |> push_event("clipboard", %{text: url})
       |> put_flash(:info, "URL copied to clipboard")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_visibility", %{"tincture" => tincture_id}, socket) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id))

    if tincture do
      ctx = socket.assigns.context

      with :ok <- Sanctum.Context.authorize(ctx, :execute) do
        # Public-ness is a published profile, not a toggle: publishing is
        # the proof-bound profile.publish walk, unpublishing revokes the
        # public profile. Until the sheet drives publish here, say so.
        message =
          case tincture.public do
            true ->
              "Unpublish by revoking the public profile (profile.revoke)."

            false ->
              "Publish through the consent walk: profile.publish on this " <>
                "tincture's owner profile."

            :unknown ->
              "This tincture's visibility can't be read right now. Try again shortly."
          end

        {:noreply, put_flash(socket, :info, message)}
      else
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_report", %{"tincture" => tincture_id}, socket) do
    case Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tincture not found; refresh and try again.")}

      tincture ->
        ref =
          Prima.ComponentRef.build(
            "tincture",
            tincture.publisher,
            tincture.name,
            tincture.version
          )

        PrismWeb.ReportComponent.open("report", ref)
        {:noreply, socket}
    end
  end

  # The bridge asks for the frame's credential once, on the frame's first
  # load, and posts it over the port it hands the frame — a canvas frame's
  # beside its `canvas` block. The bearer leaves this process once: a second ask —
  # a reload, a navigation inside the frame, another script on the page —
  # is answered with nothing.
  def handle_event("frame_handshake", %{"frame" => frame_id}, socket) do
    case Frames.handshake(socket.assigns.frames, frame_id) do
      {:ok, reply, frame, frames} ->
        socket = assign(socket, :frames, frames)
        {:reply, reply, handshaken(socket, frame)}

      :error ->
        {:reply, %{error: "no_credential"}, socket}
    end
  end

  def handle_event("frame_handshake", _params, socket),
    do: {:reply, %{error: "no_credential"}, socket}

  # An arrangement gesture the canvas hook sends once the gesture settles
  # (`@gesture_events`): applied to the frames and the person's layout at
  # once, and written with the next write (`schedule_write/1`). Answered
  # `%{ok: true}`, or `%{error: reason}` with nothing changed.
  def handle_event(event, params, socket) when event in @gesture_events and is_map(params) do
    case gestured(socket, event, params) do
      {:ok, socket} -> {:reply, %{ok: true}, socket}
      {:error, reason} -> {:reply, %{error: refusal_word(reason)}, socket}
    end
  end

  # A shell verb the frame posted over its port. The bridge names the frame
  # whose port it came from, and the message must name the same one, which
  # this view holds live, or, for a canvas's `ready` or `failed`, holds
  # live or frozen (`reporting/3`). A canvas or validation frame's verb is
  # a canvas's; any other frame's is a tincture's.
  def handle_event("frame_verb", %{"frame" => frame_id, "message" => message}, socket)
      when is_binary(frame_id) do
    with {:ok, %{frame: ^frame_id} = decoded} <- Prima.TinctureWire.decode_shell_message(message),
         {:ok, %{key: key} = frame} <- reporting(socket.assigns.frames, frame_id, decoded.verb) do
      if Frames.canvas_key?(key),
        do: {:noreply, canvas_verb(socket, frame, decoded)},
        else: {:noreply, shell_verb(socket, frame, decoded)}
    else
      _ -> {:noreply, drop_message(socket)}
    end
  end

  def handle_event("frame_verb", _params, socket), do: {:noreply, drop_message(socket)}

  # A canvas frame loaded a second time: its port is closed and it is
  # spent. A validation frame's death is the validation's outcome `died`;
  # the visible canvas's falls it back (`gone`); the shipped canvas's, in
  # a fallback's place, is torn down and spent (`spend/2`); any other
  # hidden canvas's is torn down, its credential revoked and its frame
  # forgotten, so showing that canvas again opens it anew.
  def handle_event("frame_gone", %{"frame" => frame_id}, socket) when is_binary(frame_id) do
    %{context: ctx, frames: frames} = socket.assigns

    case Enum.find(Frames.list(frames), &(&1.id == frame_id and Frames.canvas_key?(&1.key))) do
      %{key: {:validation, canvas_id}} ->
        {:noreply, validation_ended(socket, canvas_id, :gone)}

      %{key: {:canvas, canvas_id} = key} ->
        cond do
          Map.has_key?(socket.assigns.fallbacks, canvas_id) ->
            {:noreply, socket |> spend(canvas_id) |> frames(&Frames.discard(ctx, &1, key))}

          canvas_id == Frames.visible_canvas(frames) ->
            {:noreply, enter_fallback(socket, :gone)}

          true ->
            {:noreply, frames(socket, &Frames.discard(ctx, &1, key))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("frame_gone", _params, socket), do: {:noreply, socket}

  # The person moves to another canvas: by the switcher, which names it, or
  # by the chord or the edge strip, which name a direction. Nothing wraps.
  def handle_event("switch_canvas", params, socket) when is_map(params),
    do: {:noreply, switch_canvas(socket, switch_target(socket.assigns, params))}

  # The person's devices: the system layer's pairing prompt, one at a time.
  def handle_event("devices", _params, socket) do
    if socket.assigns.pairing_prompt do
      {:noreply, socket}
    else
      {prompt_id, socket} = next_prompt_id(socket, "pairing")
      show_prompt(%{id: prompt_id, kind: :pairing, action: :device_pairing, subject: %{}})
      {:noreply, assign(socket, :pairing_prompt, prompt_id)}
    end
  end

  # ============================================================================
  # Tracking + loading
  # ============================================================================

  defp handle_keynav(socket, "ArrowLeft"),
    do: focus_tincture(socket, socket.assigns.focused_index - 1)

  defp handle_keynav(socket, "ArrowRight"),
    do: focus_tincture(socket, socket.assigns.focused_index + 1)

  defp handle_keynav(socket, "ArrowUp"), do: cycle_preview(socket, -1)
  defp handle_keynav(socket, "ArrowDown"), do: cycle_preview(socket, +1)

  defp handle_keynav(socket, "Enter") do
    if not picker?(socket.assigns) do
      socket
    else
      case Enum.at(socket.assigns.tinctures, socket.assigns.focused_index) do
        nil -> socket
        tincture -> launch_tincture(socket, tincture.id)
      end
    end
  end

  defp handle_keynav(socket, "Escape"), do: close_active_tincture(socket)

  defp handle_keynav(socket, _key), do: socket

  defp focus_tincture(socket, idx) do
    case length(socket.assigns.tinctures) do
      0 ->
        assign(socket, focused_index: 0, current_preview_index: 0)

      len ->
        clamped = max(0, min(idx, len - 1))
        assign(socket, focused_index: clamped, current_preview_index: 0)
    end
  end

  defp cycle_preview(socket, step) do
    case Enum.at(socket.assigns.tinctures, socket.assigns.focused_index) do
      nil ->
        socket

      tincture ->
        len = length(tincture.preview_urls)

        if len < 2 do
          socket
        else
          new_idx = Integer.mod(socket.assigns.current_preview_index + step, len)
          assign(socket, :current_preview_index, new_idx)
        end
    end
  end

  defp launch_tincture(socket, tincture_id) do
    case Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id)) do
      nil -> socket
      card -> frames(socket, &Frames.launch(socket.assigns.context, &1, card))
    end
  end

  # A launch is closed; an app full over its canvas is closed as the
  # person's gesture, which leaves the layout too.
  defp close_active_tincture(socket) do
    case Frames.active(socket.assigns.frames) do
      nil ->
        socket

      %{key: {:app, canvas_id, ref}} ->
        case gesture(socket, canvas_id, {:close, ref}) do
          {:ok, socket} -> socket
          {:error, _refused} -> socket
        end

      %{key: key} ->
        frames(socket, &Frames.discard(socket.assigns.context, &1, key))
    end
  end

  # Every change to the frames goes through here, so each frame whose
  # state moved between live and frozen is signalled after the credential
  # transition that moved it, each frame newly refused for want of a
  # grant is offered the grant prompt — a canvas or validation frame
  # excepted, whose canvas asks for its grant once, itself
  # (`ask_canvas_grant/3`) — a canvas's ready deadline runs only while it
  # is shown (`ready_deadlines/2`), and a canvas that failed while hidden
  # falls back the moment it is shown.
  defp frames(socket, fun), do: put_frames(socket, fun.(socket.assigns.frames))

  defp put_frames(socket, later) do
    before = socket.assigns.frames
    # A rotated bearer reaches its frame ahead of the signal that makes the
    # frame live, and is never kept in the assigns.
    {replacements, later} = Frames.take_replacements(later)

    socket =
      replacements
      |> Enum.reduce(socket, &push_event(&2, "frame_bearer", &1))
      |> assign(:frames, later)
      |> arm_renewals(before, later)
      |> ready_deadlines(later)

    socket =
      Enum.reduce(
        Frames.signals(before, later),
        socket,
        &push_event(&2, "frame_state", &1)
      )

    ungranted =
      for %{state: :refused, refusal: :ungranted, id: id, key: key} = frame <- Frames.list(later),
          not Frames.canvas_key?(key),
          not match?(%{id: ^id}, Frames.get(before, key)),
          do: frame

    socket = Enum.reduce(ungranted, socket, &offer_grant(&2, &1))

    # A canvas that failed while hidden is shown: it falls back, as its
    # failure would have had it been shown then.
    died = socket.assigns.canvas_died

    if Enum.any?(Frames.list(later), &(&1.visible and MapSet.member?(died, &1.id))),
      do: enter_fallback(socket, :not_ready),
      else: socket
  end

  # Every listed card: the tinctures the picker lists and the canvases.
  defp cards(socket), do: socket.assigns.tinctures ++ socket.assigns.canvases

  # ============================================================================
  # Shell verbs
  # ============================================================================

  # A press and a failure are a canvas's alone (`Prima.TinctureWire.canvas_verbs/0`).
  defp shell_verb(socket, frame, %{verb: verb} = decoded) do
    if verb in Prima.TinctureWire.canvas_verbs(),
      do: drop_message(socket),
      else: tincture_verb(socket, frame, decoded)
  end

  # An app that closes itself is closed as the person's close is, on the
  # layout too, so the next arrangement does not open it again; a launch
  # from the picker is only discarded.
  defp tincture_verb(socket, %{key: {:app, canvas_id, ref}}, %{verb: :close}) do
    case gesture(socket, canvas_id, {:close, ref}) do
      {:ok, socket} -> socket
      {:error, _not_placed} -> drop_message(socket)
    end
  end

  defp tincture_verb(socket, %{key: key}, %{verb: :close}),
    do: frames(socket, &Frames.discard(socket.assigns.context, &1, key))

  defp tincture_verb(socket, _frame, %{verb: :ready}), do: socket

  # A secret is typed into the shell's own prompt, never into a frame, and
  # only for a frame the person can see whose version declares the vault
  # write the prompt makes. One prompt per frame at a time.
  defp tincture_verb(socket, %{id: id, visible: true} = frame, %{
         verb: :credential,
         args: %{"name" => name}
       }) do
    if Frames.declares?(frame, "vault.create") and
         not Enum.any?(socket.assigns.credential_prompts, &match?({_, ^id}, &1)) do
      {prompt_id, socket} = next_prompt_id(socket, "credential")

      show_prompt(%{
        id: prompt_id,
        kind: :credential_entry,
        action: :credential_entry,
        subject: %{name: name}
      })

      update(socket, :credential_prompts, &Map.put(&1, prompt_id, id))
    else
      drop_message(socket)
    end
  end

  defp tincture_verb(socket, _frame, %{verb: :credential}), do: drop_message(socket)

  defp tincture_verb(socket, %{tincture_id: tincture_id}, %{
         verb: :title,
         args: %{"title" => title}
       }) do
    tinctures =
      Enum.map(socket.assigns.tinctures, fn
        %{id: ^tincture_id} = card -> %{card | title: title}
        card -> card
      end)

    assign(socket, :tinctures, tinctures)
  end

  # `open` names a tincture this shell lists, versionless or at the
  # version it lists; anything else opens nothing.
  defp tincture_verb(socket, _frame, %{verb: :open, args: %{"ref" => ref}}) do
    case listed(socket, ref) do
      %{id: id} -> launch_tincture(socket, id)
      nil -> drop_message(socket)
    end
  end

  # The listed tincture `ref` names, versionless or at the version listed.
  defp listed(socket, ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %Prima.ComponentRef{type: "tincture"} = parsed} ->
        Enum.find(socket.assigns.tinctures, &lists?(&1, parsed))

      _ ->
        nil
    end
  end

  defp lists?(card, parsed) do
    card.publisher == parsed.namespace and card.name == parsed.name and
      parsed.version in [nil, card.version]
  end

  defp drop_message(socket) do
    Logger.debug("[ShellLive] frame message dropped")
    assign(socket, :frames, Frames.drop_message(socket.assigns.frames))
  end

  # ============================================================================
  # Canvas verbs
  # ============================================================================

  # The frame a verb is attributed to: the live frame `frame_id` names; or,
  # for a canvas's `ready` or `failed`, which report how its page loaded
  # and runs rather than act, a canvas frame held frozen too, since a
  # hidden canvas's page still loads and can fail.
  defp reporting(frames, frame_id, verb) do
    case Frames.attribute(frames, frame_id) do
      {:ok, frame} ->
        {:ok, frame}

      :error when verb in [:ready, :failed] ->
        case Enum.find(Frames.list(frames), &(&1.id == frame_id)) do
          %{key: {:canvas, _}, state: :frozen} = frame -> {:ok, frame}
          _another -> :error
        end

      :error ->
        :error
    end
  end

  # From a validation frame, only its `ready` and its failure act.
  defp canvas_verb(socket, %{key: {:validation, canvas_id}}, %{verb: :ready}),
    do: validation_ended(socket, canvas_id, :ready)

  defp canvas_verb(socket, %{key: {:validation, canvas_id}}, %{verb: :failed}),
    do: validation_ended(socket, canvas_id, :failed)

  defp canvas_verb(socket, %{key: {:validation, _}}, _verb), do: drop_message(socket)

  # From the canvas the glass shows, live, `ready`, a failure at either
  # stage, `open` and `press` act. A hidden canvas, frozen or not the one
  # shown, acts on nothing, but its `ready` makes it ready and its failure
  # marks it died, which falls it back once it is shown (`put_frames/2`).
  defp canvas_verb(socket, %{key: {:canvas, canvas_id}, state: state} = frame, decoded) do
    shown = state == :live and canvas_id == Frames.visible_canvas(socket.assigns.frames)

    case decoded do
      _any when shown -> live_canvas_verb(socket, frame, decoded)
      %{verb: :ready} -> update(socket, :canvas_ready, &MapSet.put(&1, frame.id))
      %{verb: :failed} -> if ready?(socket, frame), do: socket, else: died(socket, frame)
      _acts -> drop_message(socket)
    end
  end

  defp live_canvas_verb(socket, %{id: id}, %{verb: :ready}),
    do: update(socket, :canvas_ready, &MapSet.put(&1, id))

  # A page error after the canvas reported ready is not a crash: only a
  # canvas that fails before its `ready` falls back.
  defp live_canvas_verb(socket, frame, %{verb: :failed}) do
    if ready?(socket, frame), do: socket, else: enter_fallback(socket, :not_ready)
  end

  defp live_canvas_verb(socket, %{key: {:canvas, canvas_id}}, %{
         verb: :open,
         args: %{"ref" => ref}
       }),
       do: open_from_canvas(socket, canvas_id, ref)

  defp live_canvas_verb(socket, frame, %{verb: :press, args: args}),
    do: press(socket, frame, args)

  defp live_canvas_verb(socket, _frame, %{verb: :grant, args: %{"ref" => ref}}),
    do: grant_from_canvas(socket, ref)

  defp live_canvas_verb(socket, _frame, _another_verb), do: drop_message(socket)

  defp ready?(socket, %{id: id}), do: MapSet.member?(socket.assigns.canvas_ready, id)

  # The person asked, from the canvas, for their grant to an installed
  # component: offered through the system layer's generic grant path (the
  # one AQUA's own asks take: Sanctum's preview, which the person confirms
  # or not), and its outcome waits on no frame, since the component is
  # most often a catalyst with none. Dropped and counted, offering nothing,
  # when the reference names nothing installed, when an offer for the
  # component is already open, or when the component is already granted.
  defp grant_from_canvas(socket, ref) do
    ctx = socket.assigns.context

    with {:ok, component} <- installed_component(ctx, ref),
         false <- offering?(socket.assigns.grant_prompts, component),
         false <- granted?(ctx, component),
         {:ok, offered} <- grant_prompt(socket, {:component, component}, nil, component) do
      offered
    else
      _refused -> drop_message(socket)
    end
  end

  # The component `ref` names among the athanor's installed ones, versionless
  # or at an installed version, as the grant names it: without its version.
  defp installed_component(ctx, ref) do
    with {:ok, %{"component_ref" => canonical}} <- Compendium.inspect_component(ctx, ref),
         {:ok, parsed} <- Prima.ComponentRef.parse(canonical) do
      {:ok, Prima.ComponentRef.to_string(%{parsed | version: nil})}
    else
      _none -> :error
    end
  end

  defp offering?(prompts, component),
    do: Enum.any?(prompts, &match?({_id, {{:component, ^component}, _}}, &1))

  # Granted: an active profile of the person's for the component. A store
  # that cannot answer decides nothing here; the offer's own plan does.
  defp granted?(ctx, component) do
    case Sanctum.Consent.profiles(ctx, component) do
      {:ok, entries} -> Enum.any?(entries, &(&1.status == :active))
      {:error, _unreadable} -> false
    end
  end

  defp died(socket, %{id: id}), do: update(socket, :canvas_died, &MapSet.put(&1, id))

  # A listed tincture the canvas opens is the person's open: placed where
  # the layout has it, or opened as `Prism.Arrangement.open/4` places it,
  # and written to the layout with the next write.
  defp open_from_canvas(socket, canvas_id, ref) do
    with :ok <- arranging(socket),
         %{} = card <- listed(socket, ref),
         {:ok, opened} <- gesture(socket, canvas_id, open_gesture(socket, canvas_id, card)) do
      opened
    else
      _refused -> drop_message(socket)
    end
  end

  # A press names a binding by its id and one of its actions. It acts only
  # when the binding is a live feed of the athanor and the served version's
  # declaration reads that feed's results; it then goes to `feed.press`
  # under the shell's context. A refusal is logged by its class alone, and
  # the canvas is told nothing.
  defp press(socket, frame, %{"binding" => binding, "action" => action}) do
    with {:ok, feeds} <- Opus.feeds(socket.assigns.context),
         %{binding: %{name: feed}} <- Enum.find(feeds, &(&1.binding_id == binding)),
         true <- reads_feed?(frame, feed) do
      case call_tool(socket, "feed/press", %{"binding" => binding, "action_name" => action}) do
        {:ok, _pressed} ->
          socket

        {:error, reason} ->
          class = Prima.Refusal.classify(reason).class
          Logger.info("[ShellLive] a canvas's press was refused: #{class}")
          socket
      end
    else
      _not_pressable -> drop_message(socket)
    end
  end

  defp reads_feed?(%{canvas: %{"streams" => streams}}, feed),
    do: %{"name" => @feed_stream, "subject" => feed} in streams

  defp reads_feed?(_frame, _feed), do: false

  # A frame took its credential: a canvas or validation frame is sent the
  # tinctures it may open.
  defp handshaken(socket, %{key: {kind, _}, id: frame_id}) when kind in [:canvas, :validation],
    do: push_installed(socket, [frame_id])

  defp handshaken(socket, _frame), do: socket

  # A canvas's ready deadline runs only while the glass shows it, since a
  # hidden canvas reads and acts on nothing and so owes no `ready`. A shown
  # canvas that is not ready and holds no deadline is given the whole
  # period from now: from its open, when it opens shown, or from the
  # moment it is shown again. The deadline of a canvas no longer shown —
  # hidden, refused or gone — is cancelled, so one hidden before it was
  # ready is given the whole period again once shown, and one ready
  # before it was hidden stays ready and is given none. One deadline per
  # frame at a time, held with the token its message carries, so the
  # message of a cancelled timer already sent changes nothing.
  defp ready_deadlines(socket, frames) do
    %{canvas_deadlines: held, canvas_ready: ready} = socket.assigns
    shown = shown_canvases(frames)

    {kept, cancelled} = Map.split_with(held, fn {id, _} -> MapSet.member?(shown, id) end)
    Enum.each(cancelled, fn {_id, {timer, _token}} -> Process.cancel_timer(timer) end)

    shown
    |> Enum.reject(&(Map.has_key?(kept, &1) or MapSet.member?(ready, &1)))
    |> Enum.reduce(assign(socket, :canvas_deadlines, kept), &arm_ready_deadline(&2, &1))
  end

  defp arm_ready_deadline(socket, frame_id) do
    token = make_ref()
    timer = Process.send_after(self(), {:canvas_deadline, frame_id, token}, @canvas_ready_ms)
    update(socket, :canvas_deadlines, &Map.put(&1, frame_id, {timer, token}))
  end

  # The ids of the canvas frames the glass shows: live and visible.
  defp shown_canvases(frames) do
    for %{key: {:canvas, _}, state: :live, visible: true, id: id} <- Frames.list(frames),
        into: MapSet.new(),
        do: id
  end

  # A renewal is armed for each frame the view renews whose deadline is new
  # to it: a frame just opened, one shown again, or one whose renewal moved
  # its deadline later. A renewal that answered no later deadline arms
  # nothing more, so a credential capped by its session's end runs out. A
  # frame the view no longer renews has its renewal cancelled.
  defp arm_renewals(socket, before, later) do
    socket =
      Enum.reduce(Frames.list(later), socket, fn frame, socket ->
        with true <- Frames.renewable?(frame),
             true <- new_deadline?(Frames.get(before, frame.key), frame),
             {:ok, delay} <- renewal_delay(frame.deadline) do
          arm_renewal(socket, frame.id, frame.deadline, delay)
        else
          _not_armed -> socket
        end
      end)

    renewed =
      for frame <- Frames.list(later), Frames.renewable?(frame), into: MapSet.new(), do: frame.id

    {kept, gone} =
      Map.split_with(socket.assigns.renewals, fn {id, _} -> MapSet.member?(renewed, id) end)

    Enum.each(gone, fn {_id, {timer, _token}} -> Process.cancel_timer(timer) end)
    assign(socket, :renewals, kept)
  end

  defp new_deadline?(%{id: id, deadline: %DateTime{} = held} = before, %{
         id: id,
         deadline: deadline
       }),
       do: not Frames.renewable?(before) or DateTime.compare(deadline, held) == :gt

  defp new_deadline?(_before, _frame), do: true

  # Five minutes before the deadline, or half the life left when that is
  # under ten minutes; never sooner than the retry interval, and nothing
  # for a deadline already past.
  defp renewal_delay(deadline) do
    left = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)

    cond do
      left <= 0 -> :none
      left >= 2 * @renew_ahead_ms -> {:ok, left - @renew_ahead_ms}
      true -> {:ok, max(div(left, 2), @renew_retry_ms)}
    end
  end

  defp retry_renewal(socket, frame_id, deadline) do
    if DateTime.diff(deadline, DateTime.utc_now(), :millisecond) > @renew_retry_ms,
      do: arm_renewal(socket, frame_id, deadline, @renew_retry_ms),
      else: socket
  end

  # One renewal per frame: arming one cancels the one before it, and the
  # message carries a token the view matches, so a timer cancelled too
  # late changes nothing.
  defp arm_renewal(socket, frame_id, deadline, delay) do
    case socket.assigns.renewals do
      %{^frame_id => {timer, _token}} -> Process.cancel_timer(timer)
      _none -> :ok
    end

    token = make_ref()
    timer = Process.send_after(self(), {:frame_renewal, frame_id, deadline, token}, delay)
    update(socket, :renewals, &Map.put(&1, frame_id, {timer, token}))
  end

  # What `installed` carries to canvas `canvas_id`: every listed tincture
  # that is not a canvas, as a versionless reference, its name, its emoji
  # (none for one the wire does not carry) and whether the layout places it
  # over that canvas, minimised included, sorted by name, within the bounds
  # the canvas's reader holds it to (`Prima.TinctureWire`).
  defp installed(socket, canvas_id) do
    max_name = Prima.TinctureWire.max_installed_name()
    max_icon = Prima.TinctureWire.max_installed_icon()

    placed =
      case Enum.find(socket.assigns.arrangement || [], &(&1.id == canvas_id)) do
        %{apps: apps} -> Enum.map(apps, & &1.tincture)
        nil -> []
      end

    socket.assigns.tinctures
    |> Enum.map(fn card ->
      ref = Frames.ref_of(card)
      icon = card.icon_emoji

      %{
        ref: ref,
        name: card.name,
        icon: if(is_binary(icon) and code_points(icon) <= max_icon, do: icon),
        open: ref in placed
      }
    end)
    |> Enum.filter(&(code_points(&1.name) in 1..max_name))
    |> Enum.sort_by(& &1.name)
    |> Enum.take(Prima.TinctureWire.max_installed())
  end

  # The wire bounds names and icons in code points, as the canvas's reader
  # counts them, not in graphemes.
  defp code_points(text), do: text |> String.codepoints() |> length()

  # `installed`, to each canvas frame named, with the marks of its own
  # canvas.
  defp push_installed(socket, frame_ids) do
    frames = Frames.list(socket.assigns.frames)

    Enum.reduce(frame_ids, socket, fn frame_id, socket ->
      case Enum.find(frames, &(&1.id == frame_id)) do
        %{key: key} ->
          canvas = Frames.canvas_of(key)
          tinctures = installed(socket, canvas)

          socket
          |> push_event("canvas_installed", %{frame: frame_id, tinctures: tinctures})
          |> update(:told, &Map.put(&1, canvas, tinctures))

        nil ->
          socket
      end
    end)
  end

  defp canvas_frame_ids(frames),
    do: for(%{key: key, id: id} <- Frames.list(frames), Frames.canvas_key?(key), do: id)

  # ============================================================================
  # Arrangement gestures and the layout's writes
  # ============================================================================

  # A gesture event read into a gesture on an app of the visible canvas:
  # one naming a frame names an app frame this view holds over the canvas
  # the glass shows live; one naming a reference names a listed tincture.
  defp gestured(socket, event, params) do
    with :ok <- arranging(socket),
         {:ok, canvas_id, gesture} <- read_gesture(socket, event, params) do
      gesture(socket, canvas_id, gesture)
    end
  end

  defp arranging(%{assigns: %{document: nil}}), do: {:error, :no_layout}

  # The visible canvas is arranged while the glass shows it: under one of
  # its own full apps, as in the hand, but not under a launch from the
  # picker.
  defp arranging(%{assigns: %{frames: frames}}) do
    cond do
      is_nil(Frames.visible_canvas(frames)) -> {:error, :no_canvas}
      match?(%{key: {:full, _}}, Frames.active(frames)) -> {:error, :hidden}
      true -> :ok
    end
  end

  defp read_gesture(socket, event, %{"ref" => ref}) when event in ["app_open", "app_restore"] do
    canvas_id = Frames.visible_canvas(socket.assigns.frames)

    case listed(socket, ref) do
      %{} = card when event == "app_open" ->
        {:ok, canvas_id, open_gesture(socket, canvas_id, card)}

      %{} = card ->
        {:ok, canvas_id, {:restore, Frames.ref_of(card)}}

      nil ->
        {:error, :not_listed}
    end
  end

  defp read_gesture(socket, event, %{"frame" => frame_id} = params) when is_binary(frame_id) do
    frames = socket.assigns.frames
    canvas_id = Frames.visible_canvas(frames)

    case Enum.find(Frames.list(frames), &(&1.id == frame_id)) do
      %{key: {:app, ^canvas_id, ref}} ->
        with {:ok, gesture} <- frame_gesture(event, ref, params), do: {:ok, canvas_id, gesture}

      %{key: {:app, _another, _ref}} ->
        {:error, :hidden}

      _none ->
        {:error, :not_held}
    end
  end

  defp read_gesture(_socket, _event, _params), do: {:error, :malformed}

  defp frame_gesture("frame_move", ref, %{"geometry" => geometry}) do
    with {:ok, geometry} <- geometry(geometry), do: {:ok, {:move, ref, geometry}}
  end

  defp frame_gesture("frame_resize", ref, %{"geometry" => geometry}) do
    with {:ok, geometry} <- geometry(geometry), do: {:ok, {:resize, ref, geometry}}
  end

  defp frame_gesture("frame_resize", ref, %{"share" => share}) when is_integer(share),
    do: {:ok, {:resize, ref, share}}

  defp frame_gesture("frame_tile", ref, %{"side" => side, "share" => share})
       when side in ["left", "right"] and is_integer(share),
       do: {:ok, {:tile, ref, String.to_existing_atom(side), share}}

  defp frame_gesture("frame_full", ref, _params), do: {:ok, {:full, ref}}
  defp frame_gesture("frame_minimise", ref, _params), do: {:ok, {:minimise, ref}}
  defp frame_gesture("frame_raise", ref, _params), do: {:ok, {:raise, ref}}
  defp frame_gesture("frame_close", ref, _params), do: {:ok, {:close, ref}}
  defp frame_gesture(_event, _ref, _params), do: {:error, :malformed}

  # Whole numbers only: their bounds are the layout's (`Prima.Layout`).
  defp geometry(%{"x" => x, "y" => y, "w" => w, "h" => h} = geometry)
       when map_size(geometry) == 4 and is_integer(x) and is_integer(y) and is_integer(w) and
              is_integer(h),
       do: {:ok, %{x: x, y: y, w: w, h: h}}

  defp geometry(_other), do: {:error, :malformed}

  # How the canvas opens `card` when the layout does not place it: the
  # tincture's own size hint, read from the declaration the rules hold.
  defp open_gesture(socket, canvas_id, card) do
    ref = Frames.ref_of(card)
    %{document: document, posture: posture} = socket.assigns

    size =
      case Compendium.tincture_declaration(card.manifest) do
        {:ok, declaration} -> declaration.frame.size
        {:error, _refused} -> nil
      end

    placed =
      case Prima.Layout.arrangement(document, posture) do
        {:ok, canvases} ->
          canvases |> Enum.find(%{apps: []}, &(&1.id == canvas_id)) |> Map.get(:apps) |> length()

        :error ->
          0
      end

    {:open, ref, Prism.Arrangement.open(ref, size, posture, placed)}
  end

  # The gesture made on the person's layout as this view holds it: the
  # frames follow it at once (`Prism.Frames.arrange/5`, which keeps every
  # frame still placed), every canvas is told what is open, and the
  # gesture waits for the next write.
  defp gesture(socket, canvas_id, gesture) do
    %{document: document, posture: posture, pending: pending} = socket.assigns

    case Prism.Arrangement.apply(document, canvas_id, posture, gesture) do
      {:ok, document} ->
        {:ok,
         socket
         |> assign(document: document, pending: pending ++ [{canvas_id, posture, gesture}])
         |> rearranged()
         |> schedule_write()}

      {:error, _refused} = refused ->
        refused
    end
  end

  # The frames held for the layout as this view holds it, and every canvas
  # told what is open.
  defp rearranged(socket) do
    %{document: document, posture: posture} = socket.assigns
    {:ok, arrangement} = Prima.Layout.arrangement(document, posture)

    socket
    |> assign(:arrangement, arrangement)
    |> arrange()
    |> then(&push_installed(&1, canvas_frame_ids(&1.assigns.frames)))
  end

  defp schedule_write(%{assigns: %{write_timer: nil}} = socket),
    do: assign(socket, :write_timer, Process.send_after(self(), :write_layout, @write_after_ms))

  defp schedule_write(socket), do: socket

  # The whole layout, as this view holds it, written through the layout
  # tool as the person, over the revision it was read or last written at.
  # A newer revision reloads the layout and makes the waiting gestures
  # again on it, each that still applies; a store that cannot answer is
  # tried again a few times, the frames left as they are.
  defp write_layout(%{assigns: %{pending: []}} = socket, _round), do: socket

  defp write_layout(socket, round) do
    %{document: document, layout_base: layout} = socket.assigns
    args = %{"document" => Prima.Layout.to_json(document), "revision" => layout.revision}

    case PrismWeb.Ops.call_tool(socket, "layout/edit", args) do
      {:ok, %{revision: revision, digest: digest}} ->
        assign(socket,
          layout_base: %{document: document, revision: revision, digest: digest},
          pending: [],
          write_retries: 0
        )

      {:error, reason} ->
        if conflict?(reason), do: replay(socket, round), else: retry_write(socket)
    end
  end

  defp conflict?({:conflict, _sentence}), do: true
  defp conflict?(%Prima.Refusal{class: :conflict}), do: true
  defp conflict?(_reason), do: false

  defp retry_write(%{assigns: %{write_retries: retries}} = socket)
       when retries < @write_retries do
    timer = Process.send_after(self(), :write_layout, @write_retry_ms)
    assign(socket, write_timer: timer, write_retries: retries + 1)
  end

  defp retry_write(socket), do: give_up(socket)

  # The waiting gestures are let go: the layout as last read or written is
  # the one the frames follow again, the person is told their arrangement
  # was not saved, and every later publication is read as any other.
  defp give_up(%{assigns: %{layout_base: layout}} = socket) do
    Logger.warning("[PrismWeb.ShellLive] an arrangement was not saved and is let go")

    socket
    |> assign(document: layout.document, pending: [], write_retries: 0, write_timer: nil)
    |> put_flash(:error, "Your arrangement could not be saved, so the last saved one is back.")
    |> rearranged()
  end

  # The layout read again after a write it refused for a newer revision,
  # the waiting gestures made on it, each that still applies — an app
  # another screen closed is not moved — and written again, a bounded
  # number of times.
  defp replay(socket, round) do
    %{context: ctx, posture: posture, pending: pending} = socket.assigns

    case Compendium.layout(ctx, posture) do
      {:ok, read} when round < @conflict_replays ->
        {document, kept} = remade(read.document, pending)

        # The read is a publication like any other: a canvas whose tincture
        # it changed lets the shipped canvas go before the read becomes the
        # base the next read is compared with.
        socket =
          socket
          |> assign(:layout_changed, true)
          |> apply_layout_change(read)
          |> assign(layout_base: base(read), document: document, pending: kept)
          |> rearranged()

        write_layout(socket, round + 1)

      {:ok, read} ->
        socket
        |> assign(:layout_changed, true)
        |> apply_layout_change(read)
        |> assign(layout_base: base(read))
        |> give_up()

      {:error, _unavailable} ->
        retry_write(socket)
    end
  end

  defp base(read), do: %{document: read.document, revision: read.revision, digest: read.digest}

  defp remade(document, pending) do
    Enum.reduce(pending, {document, []}, fn {canvas_id, posture, gesture} = made, {doc, kept} ->
      case Prism.Arrangement.apply(doc, canvas_id, posture, gesture) do
        {:ok, doc} -> {doc, kept ++ [made]}
        {:error, _no_longer} -> {doc, kept}
      end
    end)
  end

  defp refusal_word({:invalid, _sentence}), do: "invalid"
  defp refusal_word(reason) when is_atom(reason), do: Atom.to_string(reason)

  # ============================================================================
  # The canvases
  # ============================================================================

  # The canvas the glass shows, as the arrangement read places it, or nil.
  defp visible_entry(%{arrangement: arrangement, frames: frames}) when is_list(arrangement) do
    canvas = Frames.visible_canvas(frames)
    Enum.find(arrangement, &(&1.id == canvas))
  end

  defp visible_entry(_assigns), do: nil

  # The arrangement placed, and then each canvas told what is open over it
  # if that changed (`tell_changed/1`).
  defp place(socket), do: socket |> arrange() |> tell_changed()

  # Hold the frames the arrangement places over the visible canvas, and
  # the canvas itself.
  defp arrange(%{assigns: %{arrangement: nil}} = socket), do: socket

  defp arrange(socket) do
    %{context: ctx, arrangement: arrangement} = socket.assigns

    socket
    |> frames(&Frames.arrange(ctx, &1, arrangement, cards(socket), socket.assigns.posture))
    |> show_canvas()
  end

  # The visible canvas, as it now stands: a validation or a canvas frame
  # held for it is kept, unless the frame runs a tincture the layout no
  # longer names for it, which is torn down with no call — a trial's
  # credential revoked and nothing activated; otherwise the shell decides
  # what to open. The system layer then draws the notice of the canvas
  # shown, if it fell back (`sync_notice/1`).
  defp show_canvas(socket), do: socket |> show_visible() |> sync_notice()

  defp show_visible(socket) do
    socket = withdraw_hidden(socket)
    %{context: ctx, frames: frames} = socket.assigns

    case visible_entry(socket.assigns) do
      nil ->
        assign(socket, :showing, :none)

      %{id: id} = entry ->
        case Frames.get(frames, {:validation, id}) || Frames.get(frames, {:canvas, id}) do
          nil ->
            decide(socket, entry)

          %{key: key} = frame ->
            if runs?(socket, frame, entry),
              do: assign(socket, :showing, :canvas),
              else: socket |> frames(&Frames.discard(ctx, &1, key)) |> show_visible()
        end
    end
  end

  defp runs?(socket, %{reference: reference}, entry) do
    running = Prima.ComponentRef.build("tincture", reference.publisher, reference.name)

    if Map.has_key?(socket.assigns.fallbacks, entry.id),
      do: running == Fallback.shipped_canvas(),
      else: running == entry.tincture
  end

  # What a canvas with no frame held opens: the shipped canvas, for one
  # fallen back; nothing for a tincture nobody installed; the fallback for
  # one installed as anything but a local canvas; otherwise its versions
  # decide whether its newest version is validated first or its working
  # version opens. The listing is read again first (`reread_listing/1`),
  # and every branch is decided against that one read: what is installed,
  # and as what, is the registry's now, never the listing's from when the
  # shell mounted. A grant prompt the canvas raised for another tincture
  # is withdrawn first (`withdraw_moved/3`), and what earlier trials of
  # the canvas were started at a validation's end is forgotten.
  defp decide(socket, entry) do
    socket =
      socket
      |> reread_listing()
      |> update(:trialled, &Map.delete(&1, entry.id))

    socket = withdraw_moved(socket, entry.id, deciding_for(socket, entry))

    cond do
      MapSet.member?(socket.assigns.spent, entry.id) ->
        assign(socket, :showing, :canvas)

      Map.has_key?(socket.assigns.fallbacks, entry.id) ->
        open_shipped(socket, entry)

      card = Frames.resolve(entry.tincture, socket.assigns.canvases) ->
        if card.publisher == Prima.ComponentPath.default_publisher(),
          do: versions(socket, entry, card),
          else: enter_fallback(socket, :not_ready)

      Frames.resolve(entry.tincture, socket.assigns.tinctures) ->
        enter_fallback(socket, :not_ready)

      true ->
        assign(socket, :showing, :none)
    end
  end

  # The card id of the tincture `decide/2` decides canvas `entry` for:
  # the shipped canvas's for one fallen back, the listed card the layout
  # names, or none.
  defp deciding_for(socket, entry) do
    card =
      if Map.has_key?(socket.assigns.fallbacks, entry.id),
        do: %{id: "iframe_" <> shipped_name()},
        else:
          Frames.resolve(entry.tincture, socket.assigns.canvases) ||
            Frames.resolve(entry.tincture, socket.assigns.tinctures)

    card && card.id
  end

  defp versions(socket, entry, card) do
    case Compendium.canvas_versions(socket.assigns.context, card.name) do
      {:ok, %{document: document}} ->
        if CanvasValidation.needed?(document, card.version),
          do: validate(socket, entry, card),
          else: open_working(socket, entry, card, document.working, :else_fallback, :ask)

      {:error, _refused} ->
        enter_fallback(socket, :not_ready)
    end
  end

  # The candidate's validation frame. Refused at its open, it holds no
  # credential and is torn down at once: for want of a grant, the grant
  # prompt is asked as activation's `consent_required` asks it; otherwise
  # the working version opens, or the canvas shows the refusal.
  defp validate(socket, %{id: id} = entry, card) do
    ctx = socket.assigns.context
    socket = socket |> decided(id) |> frames(&CanvasValidation.open(ctx, &1, id, card))

    case Frames.get(socket.assigns.frames, {:validation, id}) do
      %{state: :refused, refusal: :ungranted} ->
        socket
        |> frames(&CanvasValidation.cancel(ctx, &1, id))
        |> ask_validation_grant(entry, card)

      %{state: :refused, refusal: refusal} ->
        socket
        |> frames(&CanvasValidation.cancel(ctx, &1, id))
        |> show_working(entry, {:else_refuse, refusal}, :ask)

      _validating ->
        assign(socket, :showing, :canvas)
    end
  end

  # A validation ended for `event`: its frame is torn down, `canvas.activate`
  # is called once, and the shell goes on as its answer says.
  defp validation_ended(socket, canvas_id, event) do
    %{context: ctx, frames: frames} = socket.assigns
    tried = tried(frames, canvas_id)
    call = fn tool, args -> call_tool(socket, tool, args) end
    {later, next} = CanvasValidation.conclude(ctx, frames, canvas_id, event, call)
    socket = put_frames(socket, later)

    case {next, visible_entry(socket.assigns)} do
      {:none, _entry} ->
        socket

      {_next, %{id: ^canvas_id} = entry} ->
        socket |> decided(canvas_id) |> after_activation(entry, next, tried)

      {_next, _another} ->
        decided(socket, canvas_id)
    end
  end

  # The version canvas `canvas_id`'s validation frame trials, while held.
  defp tried(frames, canvas_id) do
    case Frames.get(frames, {:validation, canvas_id}) do
      %{reference: %{version: version}} -> version
      nil -> nil
    end
  end

  # The end of a validation is a moment the glass is to show the canvas,
  # so it compares again against the listing and the versions read now: a
  # newest version written meanwhile that needs validating
  # (`CanvasValidation.needed?/2`), and is neither the version just tried
  # nor one this path trialled since the canvas was last decided, is
  # validated in its turn; otherwise the working version opens. Each
  # version is trialled from here once per decision, so an outcome that
  # records nothing cannot loop.
  defp after_activation(socket, entry, {:show_working, fallback}, tried) do
    socket = reread_listing(socket)

    case Frames.resolve(entry.tincture, socket.assigns.canvases) do
      nil ->
        assign(socket, :showing, :none)

      card ->
        versions = Compendium.canvas_versions(socket.assigns.context, card.name)
        trialled = Map.get(socket.assigns.trialled, entry.id, MapSet.new())

        if newer?(trialled, card, tried, versions),
          do:
            socket
            |> update(:trialled, &Map.put(&1, entry.id, MapSet.put(trialled, card.version)))
            |> validate(entry, card),
          else: working_of(socket, entry, card, versions, fallback, :ask)
    end
  end

  defp after_activation(socket, entry, :ask_grant, _tried) do
    case Frames.resolve(entry.tincture, socket.assigns.canvases) do
      nil -> assign(socket, :showing, :none)
      card -> ask_validation_grant(socket, entry, card)
    end
  end

  defp after_activation(socket, entry, {:refuse, refusal}, _tried),
    do: refuse_canvas(socket, entry, refusal)

  defp newer?(trialled, card, tried, {:ok, %{document: document}}) do
    card.version != tried and not MapSet.member?(trialled, card.version) and
      CanvasValidation.needed?(document, card.version)
  end

  defp newer?(_trialled, _card, _tried, {:error, _refused}), do: false

  # Read the canvas's versions again and open its working version, or,
  # without one, `fallback`: the fallback `not_validated`, or the canvas's
  # refusal. `ask` is whether a working version refused for want of its
  # grant asks for it (`open_live/4`).
  defp show_working(socket, entry, fallback, ask) do
    case Frames.resolve(entry.tincture, socket.assigns.canvases) do
      nil ->
        assign(socket, :showing, :none)

      card ->
        versions = Compendium.canvas_versions(socket.assigns.context, card.name)
        working_of(socket, entry, card, versions, fallback, ask)
    end
  end

  defp working_of(socket, entry, card, {:ok, %{document: %{working: working}}}, fallback, ask),
    do: open_working(socket, entry, card, working, fallback, ask)

  defp working_of(socket, entry, card, {:error, _refused}, fallback, ask),
    do: open_working(socket, entry, card, nil, fallback, ask)

  defp open_working(socket, _entry, _card, nil, :else_fallback, _ask),
    do: enter_fallback(socket, :not_validated)

  defp open_working(socket, entry, _card, nil, {:else_refuse, refusal}, _ask),
    do: refuse_canvas(socket, entry, refusal)

  defp open_working(socket, entry, card, working, _fallback, ask) do
    case card_at(socket.assigns.context, card, working) do
      {:ok, card} -> open_live(socket, entry, card, ask)
      :error -> enter_fallback(socket, :not_ready)
    end
  end

  # The live canvas, opened unless a frame of it is held already: that
  # frame, live or refused, stands, and nothing of it is read as this
  # open's answer. Refused at its own open for want of a grant, it shows
  # its refusal, never the fallback, and is offered the grant prompt once,
  # kept as the canvas's (`ask_canvas_grant/3`) — `:quiet` in answer to
  # the person's dismissal of one, which asks nothing again. Any other
  # refusal at its own open falls it back (`not_ready`).
  defp open_live(socket, %{id: canvas_id} = entry, card, ask) do
    if Frames.get(socket.assigns.frames, {:canvas, canvas_id}) do
      assign(socket, :showing, :canvas)
    else
      ctx = socket.assigns.context

      socket =
        socket |> decided(canvas_id) |> frames(&Frames.open_canvas(ctx, &1, canvas_id, card))

      case Frames.get(socket.assigns.frames, {:canvas, canvas_id}) do
        %{state: :refused, refusal: :ungranted} ->
          refused = assign(socket, :showing, :canvas)

          with :ask <- ask,
               {:ok, asked} <- ask_canvas_grant(refused, entry, card) do
            asked
          else
            _quiet_or_unavailable -> refused
          end

        %{state: :refused} ->
          enter_fallback(socket, :not_ready)

        # Opened: shown, with its ready deadline armed (`ready_deadlines/2`),
        # or frozen behind a full frame, with none until it is shown. Or
        # opened frozen and dropped when its suspension could not be
        # recorded: no frame is held, and the canvas is drawn empty.
        _opened_or_dropped ->
          assign(socket, :showing, :canvas)
      end
    end
  end

  # The canvas shows its refusal, never the fallback. Held as it is, so a
  # refusal for want of a grant asks nothing again until the canvas is
  # decided again (`forget_refusal/3`). A refusal newly held is a decision
  # about the canvas.
  defp refuse_canvas(socket, entry, refusal) do
    card =
      Frames.resolve(entry.tincture, socket.assigns.canvases) ||
        Frames.resolve(entry.tincture, socket.assigns.tinctures)

    case card do
      nil ->
        assign(socket, :showing, :none)

      card ->
        socket =
          if Frames.get(socket.assigns.frames, {:canvas, entry.id}),
            do: socket,
            else: decided(socket, entry.id)

        socket
        |> assign(:frames, Frames.refuse_canvas(socket.assigns.frames, entry.id, card, refusal))
        |> assign(:showing, :canvas)
    end
  end

  # Every decision about a canvas — a trial started, an outcome, an open,
  # a refusal — is counted, so a grant prompt an earlier decision raised
  # is known to be stale (`superseded?/2`).
  defp decided(socket, canvas_id),
    do: update(socket, :decisions, &Map.update(&1, canvas_id, 1, fn count -> count + 1 end))

  # The listed card at `version`: the listed one, or that version's own
  # manifest read from its component row.
  defp card_at(_ctx, %{version: version} = card, version), do: {:ok, card}

  defp card_at(ctx, card, version) do
    ref = Prima.ComponentRef.build("tincture", card.publisher, card.name, version)

    with {:ok, %{"manifest" => stored}} <- Compendium.inspect_component(ctx, ref),
         {:ok, manifest} <- Prima.Manifest.decode_strict(stored) do
      {:ok, %{card | version: version, manifest: manifest}}
    else
      _unreadable -> :error
    end
  end

  # The fallback's shipped canvas, on this glass alone: the newest version
  # the install media ships, opened live with no validation and no write.
  # One that cannot be read leaves the place empty beside the notice.
  defp open_shipped(socket, entry) do
    ctx = socket.assigns.context
    name = shipped_name()

    with {:ok, [version | _older]} <- Compendium.shipped_versions("tincture", name),
         {:ok, card} <- shipped_card(socket, name, version) do
      open_live(socket, entry, card, :ask)
    else
      _unavailable ->
        Logger.info("[ShellLive] the shipped canvas could not be read for #{ctx.athanor_id}")
        assign(socket, :showing, :none)
    end
  end

  defp shipped_name do
    {:ok, %Prima.ComponentRef{name: name}} = Prima.ComponentRef.parse(Fallback.shipped_canvas())
    name
  end

  defp shipped_card(socket, name, version) do
    base =
      Frames.resolve(Fallback.shipped_canvas(), socket.assigns.canvases) ||
        %{
          id: "iframe_" <> name,
          publisher: Prima.ComponentPath.default_publisher(),
          name: name,
          version: nil,
          manifest: nil,
          entry: nil,
          athanor_segment: nil,
          public: false
        }

    card_at(socket.assigns.context, base, version)
  end

  # ---- switching -------------------------------------------------------------

  # The canvas a switch names: one of the arrangement's, or the one before
  # or after the visible canvas. Nothing past either end.
  defp switch_target(%{arrangement: nil}, _params), do: nil

  defp switch_target(%{arrangement: arrangement}, %{"canvas" => canvas})
       when is_binary(canvas) do
    if Enum.any?(arrangement, &(&1.id == canvas)), do: canvas
  end

  defp switch_target(%{arrangement: arrangement, frames: frames}, %{"direction" => direction})
       when direction in ["previous", "next"] do
    ids = Enum.map(arrangement, & &1.id)
    step = if direction == "next", do: 1, else: -1

    case Enum.find_index(ids, &(&1 == Frames.visible_canvas(frames))) do
      nil -> nil
      index when index + step < 0 -> nil
      index -> Enum.at(ids, index + step)
    end
  end

  defp switch_target(_assigns, _params), do: nil

  defp switch_canvas(socket, nil), do: socket

  defp switch_canvas(socket, canvas_id) do
    %{context: ctx, frames: frames, arrangement: arrangement} = socket.assigns
    leaving = Frames.visible_canvas(frames)

    if canvas_id == leaving do
      socket
    else
      socket
      |> forget_refusal(leaving, :ungranted)
      |> frames(fn frames ->
        frames
        |> then(&CanvasValidation.cancel(ctx, &1, leaving))
        |> then(&Frames.show(ctx, &1, canvas_id, arrangement, cards(socket)))
      end)
      |> show_canvas()
    end
  end

  # ---- the fallback ----------------------------------------------------------

  # The visible canvas falls back (`Prism.Fallback`): its frame, and a
  # validation of it, are discarded with their credentials, a grant prompt
  # it raised is withdrawn, and the shipped canvas opens in its place.
  # Every app, every other canvas and the assistant stay as they are. A
  # canvas already fallen back stays so: a second death, or the shipped
  # canvas failing in turn, changes nothing.
  defp enter_fallback(socket, reason) do
    case visible_entry(socket.assigns) do
      %{id: id} = entry ->
        if Map.has_key?(socket.assigns.fallbacks, id),
          do: socket,
          else: fall_back(socket, entry, reason)

      nil ->
        socket
    end
  end

  defp fall_back(socket, %{id: canvas_id} = entry, reason) do
    ctx = socket.assigns.context
    {notice_id, socket} = next_prompt_id(socket, "fallback")

    fallback =
      Fallback.enter(reason, %{
        canvas: canvas_id,
        tincture: entry.tincture,
        kept: kept(socket, entry)
      })

    raised =
      for {prompt_id, {{:activation, ^canvas_id}, _tincture}} <- socket.assigns.grant_prompts,
          do: prompt_id

    socket
    |> withdraw_prompts(raised)
    |> update(:fallbacks, &Map.put(&1, canvas_id, %{id: notice_id, fallback: fallback}))
    |> decided(canvas_id)
    |> frames(fn frames ->
      frames
      |> then(&CanvasValidation.cancel(ctx, &1, canvas_id))
      |> then(&Frames.discard(ctx, &1, {:canvas, canvas_id}))
    end)
    |> show_canvas()
  end

  # The version the canvas's versions document keeps, read as it falls
  # back; none when it cannot be read.
  defp kept(socket, entry) do
    with %{publisher: "local", name: name} <-
           Frames.resolve(entry.tincture, socket.assigns.canvases),
         {:ok, %{document: %{kept: kept}}} <-
           Compendium.canvas_versions(socket.assigns.context, name) do
      kept
    else
      _none -> nil
    end
  end

  # A way back chosen on the notice: the fallback ends, its shipped frame
  # is discarded, and the canvas is decided again from the layout as it
  # stands — the kept version, once restored, is its working one.
  defp leave_fallback(socket, canvas_id) do
    socket
    |> update(:fallbacks, &Map.delete(&1, canvas_id))
    |> update(:spent, &MapSet.delete(&1, canvas_id))
    |> frames(&Frames.discard(socket.assigns.context, &1, {:canvas, canvas_id}))
    |> show_canvas()
  end

  # The shipped canvas in a fallback's place died in turn: its frame is
  # torn down with its credential and renewal, the fallback and its line
  # stand, and nothing opens in the canvas's place again until the person
  # tries again, so a canvas that keeps dying never loops.
  defp spend(socket, canvas_id), do: update(socket, :spent, &MapSet.put(&1, canvas_id))

  # The canvas fallen back whose notice is `notice_id`, if any.
  defp fallen_back(fallbacks, notice_id) do
    Enum.find_value(fallbacks, fn
      {canvas_id, %{id: ^notice_id}} -> canvas_id
      _other -> nil
    end)
  end

  # The system layer draws the notice of the canvas the glass shows, if it
  # fell back, and none otherwise; it is told only when that changes.
  defp sync_notice(socket) do
    notice =
      case visible_entry(socket.assigns) do
        %{id: id} -> Map.get(socket.assigns.fallbacks, id)
        nil -> nil
      end

    if notice == socket.assigns.noticed do
      socket
    else
      send_update(PrismWeb.SystemLayer, id: PrismWeb.SystemLayer.layer_id(), notice: notice)
      assign(socket, :noticed, notice)
    end
  end

  # ============================================================================
  # System layer prompts
  # ============================================================================

  defp show_prompt(prompt),
    do: send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)

  defp withdraw_prompt(prompt_id),
    do: send_update(PrismWeb.SystemLayer, id: "system-layer", withdraw: prompt_id)

  defp next_prompt_id(socket, kind) do
    seq = socket.assigns.prompt_seq + 1
    {"#{kind}-#{seq}", assign(socket, :prompt_seq, seq)}
  end

  # A frame refused because the person has not granted what its tincture
  # version declares: the grant prompt for that version, whose sheet draws
  # the preview's rows, the tincture's frame, streams and system actions
  # among them, and binds the vault entries it needs, when the consent
  # walk's plan and preview can be read for it
  # (`PrismWeb.SystemLayer.grant_prompt/4`). Otherwise the frame shows its
  # refusal.
  defp offer_grant(socket, %{key: key, tincture_id: tincture_id, reference: reference}) do
    case grant_prompt(socket, key, tincture_id, Frames.version_ref(reference)) do
      {:ok, asked} -> asked
      :error -> socket
    end
  end

  # The canvas's grant waits for the person — a validation's activation
  # answered `consent_required`, or a trial or the live canvas was refused
  # at its open for want of it: the grant prompt for the tincture version
  # of the card whose open it was, so the grant records what that version
  # reads, a working version's as a trial's (the shipped canvas's own for
  # a canvas fallen back, never the layout's), kept as
  # `{:activation, canvas_id}`,
  # once, and answering the canvas's latest decision. While one is open
  # for the canvas and that tincture, deciding the canvas again asks
  # nothing more: that prompt stands, as the latest decision's. Confirmed,
  # the canvas is decided again.
  defp ask_canvas_grant(socket, %{id: canvas_id}, card) do
    case asking(socket.assigns.grant_prompts, canvas_id, card.id) do
      nil -> grant_prompt(socket, {:activation, canvas_id}, card.id, Frames.version_ref(card))
      prompt_id -> {:ok, answering(socket, prompt_id, {:activation, canvas_id})}
    end
  end

  # The grant prompt open for canvas `canvas_id` and the tincture of card
  # `tincture_id`, if any. One open for another tincture of that canvas is
  # never taken over, since it names a grant this decision does not ask
  # for.
  defp asking(prompts, canvas_id, tincture_id) do
    Enum.find_value(prompts, fn
      {prompt_id, {{:activation, ^canvas_id}, ^tincture_id}} -> prompt_id
      _another -> nil
    end)
  end

  # Canvas `canvas_id` is decided for the tincture of card `tincture_id`,
  # or for none: every grant prompt of the canvas for another tincture is
  # withdrawn from the system layer, which reports nothing for it, and
  # forgotten here, so the person never sees a prompt for a tincture no
  # longer in front, and its answer never reaches `grant_closed/4`.
  defp withdraw_moved(socket, canvas_id, tincture_id) do
    moved =
      for {prompt_id, {{:activation, ^canvas_id}, other}} <- socket.assigns.grant_prompts,
          other != tincture_id,
          do: prompt_id

    withdraw_prompts(socket, moved)
  end

  # A canvas's grant prompt stands only while the glass shows that canvas:
  # once the canvas leaves the screen — the layout drops it, or the person
  # switches away — its prompts are withdrawn, and showing it again
  # decides it again.
  defp withdraw_hidden(socket) do
    visible = Frames.visible_canvas(socket.assigns.frames)

    hidden =
      for {prompt_id, {{:activation, canvas_id}, _tincture}} <- socket.assigns.grant_prompts,
          canvas_id != visible,
          do: prompt_id

    withdraw_prompts(socket, hidden)
  end

  # Grant prompts `prompt_ids`, withdrawn from the system layer, which
  # reports nothing for them, and forgotten here.
  defp withdraw_prompts(socket, prompt_ids) do
    Enum.each(prompt_ids, &withdraw_prompt/1)

    socket
    |> update(:grant_prompts, &Map.drop(&1, prompt_ids))
    |> update(:grant_decisions, &Map.drop(&1, prompt_ids))
  end

  # A canvas's grant prompt `prompt_id` answers the canvas's latest
  # decision; any other prompt answers its frame.
  defp answering(socket, prompt_id, {:activation, canvas_id}) do
    decision = Map.get(socket.assigns.decisions, canvas_id, 0)
    update(socket, :grant_decisions, &Map.put(&1, prompt_id, decision))
  end

  defp answering(socket, _prompt_id, _key), do: socket

  # A validation found the canvas's grant waiting: its prompt, asked with
  # no trial held. A prompt that cannot be drawn leaves the working
  # version, or the canvas's refusal, asking nothing more.
  defp ask_validation_grant(socket, entry, card) do
    case ask_canvas_grant(socket, entry, card) do
      {:ok, asked} -> assign(asked, :showing, :canvas)
      :error -> show_working(socket, entry, {:else_refuse, :ungranted}, :quiet)
    end
  end

  defp grant_prompt(socket, key, tincture_id, ref) do
    {prompt_id, next} = next_prompt_id(socket, "grant")

    case PrismWeb.SystemLayer.grant_prompt(socket, prompt_id, ref) do
      {:ok, prompt} ->
        show_prompt(prompt)

        {:ok,
         next
         |> update(:grant_prompts, &Map.put(&1, prompt_id, {key, tincture_id}))
         |> answering(prompt_id, key)}

      {:error, _unavailable} ->
        :error
    end
  end

  # A grant confirmed: the refused frame is opened again where it was, and
  # a canvas that waited on it is decided again, its refusal first let go.
  defp granted(socket, {{:activation, canvas_id}, _tincture_id}) do
    socket
    |> forget_refusal(canvas_id, :any)
    |> place()
  end

  # A grant the canvas asked for opens nothing: no frame waited on it.
  defp granted(socket, {{:component, _component}, nil}), do: socket

  defp granted(socket, {key, tincture_id}) do
    %{context: ctx, frames: frames} = socket.assigns
    held = Frames.get(frames, key)
    socket = frames(socket, &Frames.discard(ctx, &1, key))

    case {key, held} do
      {{:full, _}, _held} ->
        launch_tincture(socket, tincture_id)

      # An app opens again where the layout places it.
      _placed ->
        place(socket)
    end
  end

  # The grant a canvas waited on was dismissed: the working version, or
  # the canvas's refusal, which stays; nothing is asked again in answer.
  defp grant_dismissed(socket, {{:activation, canvas_id}, _tincture_id}) do
    case visible_entry(socket.assigns) do
      %{id: ^canvas_id} = entry -> show_working(socket, entry, {:else_refuse, :ungranted}, :quiet)
      _another -> socket
    end
  end

  defp grant_dismissed(socket, _frame), do: socket

  # Let go of canvas `canvas_id`'s refusal, so the next show decides it
  # again: `:any` refusal once its grant is confirmed, or one for want of
  # the grant (`:ungranted`) once the glass leaves it or the layout
  # changes. A refused frame holds no credential.
  defp forget_refusal(socket, canvas_id, which) do
    case Frames.get(socket.assigns.frames, {:canvas, canvas_id}) do
      %{state: :refused, refusal: refusal} when which in [:any, refusal] ->
        frames(socket, &Frames.discard(socket.assigns.context, &1, {:canvas, canvas_id}))

      _live_another_or_none ->
        socket
    end
  end

  defp prompt_outcome(socket, id, outcome) do
    %{fallbacks: fallbacks, credential_prompts: credentials, grant_prompts: grants} =
      socket.assigns

    cond do
      canvas_id = fallen_back(fallbacks, id) ->
        case outcome do
          {:confirmed, offer} when offer in [:retry, :kept] -> leave_fallback(socket, canvas_id)
          _other -> socket
        end

      socket.assigns.pairing_prompt == id ->
        if outcome == :dismissed, do: assign(socket, :pairing_prompt, nil), else: socket

      Map.has_key?(credentials, id) ->
        credential_closed(socket, id, Map.fetch!(credentials, id), outcome)

      Map.has_key?(grants, id) ->
        grant_closed(socket, id, Map.fetch!(grants, id), outcome)

      true ->
        socket
    end
  end

  # The frame is told only that its prompt closed and whether an entry was
  # saved. A refused confirmation leaves the prompt open for the person to
  # try again or dismiss, so it closes nothing; one that was never drawn
  # closes it unsaved.
  defp credential_closed(socket, _id, _frame_id, {:refused, reason})
       when reason != :invalid_prompt,
       do: socket

  defp credential_closed(socket, id, frame_id, outcome) do
    socket = update(socket, :credential_prompts, &Map.delete(&1, id))

    if Enum.any?(Frames.list(socket.assigns.frames), &(&1.id == frame_id)),
      do:
        push_event(socket, "frame_credential", %{frame: frame_id, saved: outcome == :confirmed}),
      else: socket
  end

  defp grant_closed(socket, _id, _frame, {:refused, reason}) when reason != :invalid_prompt,
    do: socket

  defp grant_closed(socket, id, frame, outcome) do
    stale = superseded?(socket.assigns, id, frame)

    socket =
      socket
      |> update(:grant_prompts, &Map.delete(&1, id))
      |> update(:grant_decisions, &Map.delete(&1, id))

    cond do
      stale -> socket
      outcome == :confirmed -> granted(socket, frame)
      true -> grant_dismissed(socket, frame)
    end
  end

  # A canvas's grant prompt acts only while it is its canvas's latest
  # decision. Once anything has decided the canvas since — a trial
  # started, an outcome, an open, a refusal — the prompt is stale and acts
  # on nothing, dismissed or confirmed; the system layer's commit of a
  # confirmed grant stands, as a stale deadline changes nothing.
  defp superseded?(assigns, prompt_id, {{:activation, canvas_id}, _tincture_id}),
    do: Map.get(assigns.grant_decisions, prompt_id) != Map.get(assigns.decisions, canvas_id, 0)

  defp superseded?(_assigns, _prompt_id, _prompt), do: false

  defp load_tinctures(socket), do: socket |> read_listing() |> follow_listing()

  # The listing read again for a decision. A read that changes what
  # `installed` carries is pushed to every held canvas frame, as
  # `follow_listing/1` pushes it; nothing is placed.
  defp reread_listing(socket), do: socket |> read_listing() |> tell_changed()

  # Every held canvas frame is told what it may open, when that changed
  # for a held canvas since it was last told (`push_installed/2` keeps what
  # each canvas was told). A canvas not told yet is told at its handshake.
  defp tell_changed(socket) do
    told = socket.assigns.told
    now = Map.take(to_tell(socket), Map.keys(told))

    if now == Map.take(told, Map.keys(now)),
      do: socket,
      else: push_installed(socket, canvas_frame_ids(socket.assigns.frames))
  end

  # What `installed` tells each held canvas frame, by canvas.
  defp to_tell(socket) do
    for %{key: key} <- Frames.list(socket.assigns.frames),
        Frames.canvas_key?(key),
        canvas = Frames.canvas_of(key),
        into: %{},
        do: {canvas, installed(socket, canvas)}
  end

  # The listing, read once: every card the registry lists, the canvases
  # split from the tinctures the picker lists. It places nothing.
  defp read_listing(socket) do
    ctx = socket.assigns.context

    # Use the cached registry, which scans lazily and follows tincture
    # change notifications. The refresh button forces a rescan.
    cards = Enum.map(Prism.TinctureRegistry.list_tinctures(ctx), &card(ctx, &1))

    # A canvas is opened by the shell from the layout, never launched or
    # listed for the picker.
    {canvases, tinctures} = Enum.split_with(cards, &Frames.canvas?/1)

    # Clamp focused_index if the list shrank, reset preview cursor.
    focused = min(socket.assigns.focused_index || 0, max(length(tinctures) - 1, 0))

    socket
    |> assign(:tinctures, tinctures)
    |> assign(:canvases, canvases)
    |> assign(:focused_index, focused)
    |> assign(:current_preview_index, 0)
  end

  # The card of a tincture the registry lists.
  defp card(ctx, t) do
    ref = Prima.ComponentRef.build("tincture", t.publisher, t.name)

    card = %{
      id: "iframe_#{t.name}",
      name: t.name,
      publisher: t.publisher,
      athanor_id: t.athanor_id,
      athanor_segment: t.athanor_segment,
      version: t.version,
      title: t.title,
      tagline: t.tagline,
      icon: t.icon,
      icon_emoji: emoji_from_hint(t.icon),
      entry: t.entry,
      manifest: t.manifest,
      public: visibility(ctx, ref)
    }

    media = media_base(ctx, card)

    Map.merge(card, %{
      icon_url: media_url(media, t.media_icon),
      preview_urls: t.media_previews |> Enum.map(&media_url(media, &1)) |> Enum.reject(&is_nil/1)
    })
  end

  # A frame whose tincture the registry no longer lists is discarded with
  # its credential, the layout's entries are placed again against the new
  # listing, and every canvas frame is sent what it may open when that
  # changed.
  defp follow_listing(socket) do
    %{context: ctx} = socket.assigns

    socket
    |> frames(&Frames.prune(ctx, &1, cards(socket)))
    |> place()
  end

  # Public is an active public profile. A store that could not answer, or
  # a profile row that could not be decoded, is `:unknown` — never "not
  # public": the card says it cannot tell and offers no toggle.
  defp visibility(ctx, ref) do
    case Sanctum.Consent.profiles(ctx, ref) do
      {:ok, entries} ->
        cond do
          Enum.any?(entries, &(Map.get(&1, :kind) == :public and &1.status == :active)) -> true
          Enum.any?(entries, &(&1.status == :corrupt)) -> :unknown
          true -> false
        end

      {:error, _unreadable} ->
        :unknown
    end
  end

  # The picker is for when no canvas runs: a layout with no canvas, a
  # canvas whose tincture is not installed, or a layout that could not be
  # read. It is under an active full frame like everything else.
  defp picker?(%{frames: frames, showing: showing}) do
    Frames.active(frames) == nil and showing == :none
  end

  defp prompting?(%{
         credential_prompts: credentials,
         grant_prompts: grants,
         pairing_prompt: pairing
       }),
       do: credentials != %{} or grants != %{} or not is_nil(pairing)

  defp visibility_label(true), do: "public"
  defp visibility_label(false), do: "private"
  defp visibility_label(:unknown), do: "unavailable"

  # Where a card's icon and previews are read from: a public tincture's
  # public address, or a private version's files under the person's asset
  # credential. A digest or credential that cannot be had shows no images,
  # never a URL with anything else in it.
  defp media_base(_ctx, %{public: true} = card),
    do: {:public, Prima.TinctureUrl.path(card.athanor_segment, card.publisher, card.name)}

  defp media_base(ctx, card) do
    with {:ok, digest} <- Frames.version_digest(ctx, card),
         {:ok, %{credential: credential}} <- TinctureAuth.mint_asset_credential(ctx, digest) do
      {:private, credential, card}
    else
      {:error, _reason} -> :none
    end
  end

  # Only image paths the serve gate would answer: the fast reject and the
  # server-side validators read one rule map
  # (`Compendium.tincture_asset_rules/0`).
  defp media_url(:none, _path), do: nil

  defp media_url(base, path) when is_binary(path) and path != "" do
    if safe_asset_path?(path), do: served_url(base, String.split(path, "/"))
  end

  defp media_url(_base, _path), do: nil

  defp served_url({:public, address}, segments),
    do: address <> "/" <> Enum.map_join(segments, "/", &encode_segment/1)

  defp served_url({:private, credential, card}, segments),
    do: Frames.asset_path(credential, card, segments)

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp safe_asset_path?(path) do
    ext = path |> Path.extname() |> String.downcase()

    Prima.PathSafety.validate_relative_path(path) == :ok and
      ext in Compendium.tincture_asset_rules().image_extensions
  end

  defp emoji_from_hint(hint) when is_binary(hint) do
    if Regex.match?(~r/\p{Extended_Pictographic}/u, hint), do: hint, else: nil
  end

  defp emoji_from_hint(_), do: nil

  # Stable per-tincture gradient for the preview-fallback area when there are
  # no preview images.
  @gradients [
    "linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%)",
    "linear-gradient(135deg, #ec4899 0%, #f43f5e 100%)",
    "linear-gradient(135deg, #06b6d4 0%, #3b82f6 100%)",
    "linear-gradient(135deg, #10b981 0%, #14b8a6 100%)",
    "linear-gradient(135deg, #f59e0b 0%, #ef4444 100%)",
    "linear-gradient(135deg, #8b5cf6 0%, #d946ef 100%)",
    "linear-gradient(135deg, #f43f5e 0%, #f97316 100%)",
    "linear-gradient(135deg, #14b8a6 0%, #0ea5e9 100%)"
  ]

  defp gradient_for(%{publisher: pub, name: name}) do
    seed = "#{pub}/#{name}"
    Enum.at(@gradients, Integer.mod(:erlang.phash2(seed), length(@gradients)))
  end

  defp first_letter(%{title: title, name: name}) do
    str = if title && title != "", do: title, else: name

    case str |> String.trim() |> String.first() do
      nil -> "?"
      ch -> String.upcase(ch)
    end
  end

  # Every prompt the shell shows is its own: the fallback's notice,
  # pairing, a credential entry, a grant.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_report(id, outcome, socket) when is_binary(id),
    do: {:noreply, prompt_outcome(socket, id, outcome)}

  def system_layer_report(_id, _outcome, _socket), do: :pass

  # The refresh's answer, taken only under the focus it was started for.
  @impl true
  def handle_info({:deliver, tag, message}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &handle_info(message, &1))

  def handle_info({:report_component, :submitted}, socket) do
    {:noreply, put_flash(socket, :info, "Report submitted. Thanks.")}
  end

  # The canvas read the layout for the posture the client reported. While
  # gestures wait to be written, this view keeps the layout as it holds
  # it, and their write meets any newer revision (`write_layout/2`). A
  # read of the revision this view last read or wrote, its own write
  # announced among them, changes nothing it holds. Any other read is
  # taken: a layout change waiting on it is applied, then the frames it
  # places and the visible canvas are held.
  def handle_info({PrismWeb.CanvasLive, :layout, posture, read}, socket) do
    %{layout_base: layout, pending: pending} = socket.assigns

    own =
      layout != nil and layout.revision == read.revision and layout.digest == read.digest

    socket =
      if pending != [] or own,
        do: assign(socket, :layout_changed, false),
        else:
          socket
          |> apply_layout_change(read)
          |> assign(layout_base: base(read), document: read.document)

    {:ok, arrangement} = Prima.Layout.arrangement(socket.assigns.document, posture)
    {:noreply, socket |> assign(posture: posture, arrangement: arrangement) |> place()}
  end

  # The first gesture not yet written waited its window: the layout is
  # written now, with every gesture made since.
  def handle_info(:write_layout, socket) do
    {:noreply, socket |> assign(:write_timer, nil) |> write_layout(1)}
  end

  # The layout could not be read. At mount, with no canvas known, the
  # picker is drawn until a read succeeds; otherwise the glass keeps what
  # it shows, and a layout change waits for a read that succeeds.
  def handle_info({PrismWeb.CanvasLive, :layout_unavailable}, socket) do
    if socket.assigns.showing == :pending,
      do: {:noreply, assign(socket, :showing, :none)},
      else: {:noreply, socket}
  end

  # The person's layout was published — through the layout tool's edit, by
  # the CLI, the API, a glass paired with them or the assistant: read it
  # again. The change is applied only once that read succeeds
  # (`apply_layout_change/1`).
  def handle_info(%Cyfr.Bus.LayoutPublished{user_id: user_id}, socket) do
    if user_id == socket.assigns.context.user_id do
      send_update(PrismWeb.CanvasLive, id: "canvas", reload: true)
      {:noreply, assign(socket, :layout_changed, true)}
    else
      {:noreply, socket}
    end
  end

  # A shown canvas's ready deadline, armed under `token` the whole period
  # ago (`ready_deadlines/2`): without its `ready` the canvas falls back.
  # One cancelled or superseded since, or whose frame is no longer shown,
  # changes nothing.
  def handle_info({:canvas_deadline, frame_id, token}, socket) do
    %{canvas_deadlines: held, canvas_ready: ready, frames: frames} = socket.assigns

    case held do
      %{^frame_id => {_timer, ^token}} ->
        socket = assign(socket, :canvas_deadlines, Map.delete(held, frame_id))

        if MapSet.member?(shown_canvases(frames), frame_id) and
             not MapSet.member?(ready, frame_id),
           do: {:noreply, enter_fallback(socket, :not_ready)},
           else: {:noreply, socket}

      _cancelled_or_superseded ->
        {:noreply, socket}
    end
  end

  # A frame's renewal, armed for one deadline. One superseded by a later
  # arm, or for a frame no longer held live at that deadline, changes
  # nothing; one the store or the member could not answer is tried again
  # while the deadline allows.
  def handle_info({:frame_renewal, frame_id, deadline, token}, socket) do
    case socket.assigns.renewals do
      %{^frame_id => {_timer, ^token}} ->
        socket = update(socket, :renewals, &Map.delete(&1, frame_id))

        {outcome, later} =
          Frames.renew(socket.assigns.context, socket.assigns.frames, frame_id, deadline)

        socket = put_frames(socket, later)

        if outcome == :retry,
          do: {:noreply, retry_renewal(socket, frame_id, deadline)},
          else: {:noreply, socket}

      _superseded ->
        {:noreply, socket}
    end
  end

  # A validation's deadline. One for a frame no longer held changes nothing.
  def handle_info({:validation_deadline, frame_id}, socket) do
    case CanvasValidation.canvas_of(socket.assigns.frames, frame_id) do
      {:ok, canvas_id} -> {:noreply, validation_ended(socket, canvas_id, :deadline)}
      :none -> {:noreply, socket}
    end
  end

  def handle_info(:tinctures_refreshed, socket) do
    {:noreply,
     socket
     |> load_tinctures()
     |> put_flash(:info, "Tinctures registered and refreshed")}
  end

  # An archived athanor must let go of already-mounted shells — every
  # ingress gate refuses it, and a socket invoking tinctures from before
  # the archive must not be the exception.
  def handle_info(%Cyfr.Bus.Notify{athanor_id: athanor_id, kind: :athanor_changed}, socket) do
    ctx = socket.assigns.context

    if athanor_id == ctx.athanor_id and not Sanctum.Tenancy.Athanors.active?(athanor_id) do
      {:noreply,
       socket
       |> assign(:frames, Frames.revoke_all(ctx, socket.assigns.frames))
       |> put_flash(:error, "This athanor was archived.")
       |> redirect(to: "/")}
    else
      {:noreply, socket}
    end
  end

  # Other tray traffic on the athanor's topic is for the topbar, not the shell.
  def handle_info(%Cyfr.Bus.Notify{}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # A published layout, read: a canvas's fallback ends once the layout
  # names another tincture for that canvas or drops it, and
  # a canvas's refusal for want of its grant is let go, so the arrangement
  # read decides that canvas again. A publication that keeps the canvas's
  # tincture and only arranges keeps the fallback, so saving a
  # gesture never opens the canvas that failed again. Before a read
  # succeeds nothing of it is applied.
  defp apply_layout_change(%{assigns: %{layout_changed: false}} = socket, _read), do: socket

  defp apply_layout_change(socket, read) do
    canvases =
      for %{key: {:canvas, canvas_id}} <- Frames.list(socket.assigns.frames), do: canvas_id

    socket = socket |> assign(:layout_changed, false) |> drop_fallbacks(read.document)
    Enum.reduce(canvases, socket, &forget_refusal(&2, &1, :ungranted))
  end

  # A canvas's fallback ends, its shipped frame discarded, when the layout
  # now names another tincture for the canvas, or drops it, so the canvas
  # the layout names opens in its place.
  defp drop_fallbacks(socket, document) do
    %{context: ctx, fallbacks: fallbacks, document: held} = socket.assigns

    Enum.reduce(fallbacks, socket, fn {canvas_id, _fallback}, socket ->
      if canvas_tincture(held, canvas_id) == canvas_tincture(document, canvas_id) do
        socket
      else
        socket
        |> update(:fallbacks, &Map.delete(&1, canvas_id))
        |> update(:spent, &MapSet.delete(&1, canvas_id))
        |> frames(&Frames.discard(ctx, &1, {:canvas, canvas_id}))
      end
    end)
  end

  defp canvas_tincture(nil, _canvas_id), do: nil

  defp canvas_tincture(%Prima.Layout{canvases: canvases}, canvas_id) do
    case Enum.find(canvases, &(&1.id == canvas_id)) do
      %{tincture: tincture} -> tincture
      nil -> nil
    end
  end

  # Every frame credential this view minted is revoked as it ends — the
  # socket closed, the person left or navigated away, the view redirected
  # — revoked ones included, since revoking is idempotent. A view that
  # dies without reaching here leaves each row to its deadline.
  # Gestures still waiting to be written when the page ends are written
  # first (`flush_layout/1`): a switch to the Dashboard made inside the
  # write window loses nothing.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx, frames: %Frames{} = frames} ->
        flush_layout(socket)
        Frames.revoke_all(ctx, frames)
        :ok

      _unmounted ->
        :ok
    end
  end

  # The page's last write, made at most twice so the page still ends
  # promptly: one refused for a newer revision reads the layout again and
  # makes the waiting gestures that still apply on it, as a save does
  # (`replay/2`), before the second. A second refusal, or one of any other
  # kind, lets the gestures go with the page, as an exhausted retry does,
  # and says so in the log.
  defp flush_layout(
         %{assigns: %{pending: [_ | _], document: document, layout_base: layout}} = socket
       ),
       do: flush_layout(socket, document, layout.revision, 1)

  defp flush_layout(_socket), do: :ok

  defp flush_layout(socket, document, revision, attempt) do
    args = %{"document" => Prima.Layout.to_json(document), "revision" => revision}

    case PrismWeb.Ops.call_tool(socket, "layout/edit", args) do
      {:ok, _written} ->
        :ok

      {:error, reason} ->
        if conflict?(reason) and attempt < @flush_writes,
          do: flush_again(socket, attempt),
          else: flush_let_go(reason)
    end
  end

  defp flush_again(
         %{assigns: %{context: ctx, posture: posture, pending: pending}} = socket,
         attempt
       ) do
    case Compendium.layout(ctx, posture) do
      {:ok, read} ->
        case remade(read.document, pending) do
          {_document, []} -> :ok
          {document, _kept} -> flush_layout(socket, document, read.revision, attempt + 1)
        end

      {:error, reason} ->
        flush_let_go(reason)
    end
  end

  defp flush_let_go(reason) do
    Logger.warning(
      "[PrismWeb.ShellLive] an arrangement waiting as the page ended was not saved and is " <>
        "let go: " <> inspect(reason)
    )
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="shell" class="h-full relative bg-surface-base">
      <%!-- The canvas layer comes first: an element whose presence varies
           drawn before it would have the page's patch move it, and every
           frame it holds would reload. --%>
      <.live_component
        module={PrismWeb.CanvasLive}
        id="canvas"
        context={@context}
        frames={@frames}
        tinctures={@tinctures}
        arrangement={@arrangement}
      />

      <%!-- The page's keys, pushed from an element of their own: the page
           locks the element an event is pushed from until its reply, and a
           locked element around the frames keeps a frame the layer discards
           while it waits. --%>
      <div id="shell-keys" phx-window-keydown="keynav" hidden></div>

      <%!-- The shell's own chrome: no frame draws it or reaches it. --%>
      <button
        id="shell-devices"
        type="button"
        phx-click="devices"
        data-test="shell-devices"
        title="Pair or revoke a device"
        class="absolute bottom-2 left-2 z-[67] min-h-6 rounded-md bg-black/60 px-2 py-1 text-xs text-white/80 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-300"
      >
        Devices
      </button>

      <.live_component
        module={PrismWeb.SystemLayer}
        id={PrismWeb.SystemLayer.layer_id()}
        context={@context}
        athanor_route={@athanor_route}
        athanor_name={@athanor && @athanor.name}
      />

      <.live_component
        module={PrismWeb.ReportComponent}
        id="report"
        context={@context}
        athanor_route={@athanor_route}
      />

      <%!-- Picker: drawn when no canvas runs, while no tincture is
           active. It is the shell's last element, so
           drawing or hiding it moves no other one, the system layer's
           open dialog included, which a move would take out of the top
           layer. Its z-index keeps it above the canvas layer and under
           the chrome. --%>
      <div
        :if={picker?(assigns)}
        id="shell-picker"
        class="absolute inset-0 z-10 flex h-full flex-col"
      >
        <%= if @tinctures == [] do %>
          <.picker_empty_state />
        <% else %>
          <% focused = Enum.at(@tinctures, @focused_index) %>
          <% preview_count = length(focused.preview_urls) %>
          <% safe_idx =
            if preview_count > 0, do: min(@current_preview_index, preview_count - 1), else: 0 %>
          <% current_preview_url =
            if preview_count > 0, do: Enum.at(focused.preview_urls, safe_idx), else: nil %>

          <.refresh_corner />

          <div class="flex flex-1 flex-col items-center justify-center gap-6 px-12 pb-6">
            <.preview_stage
              tincture={focused}
              preview_url={current_preview_url}
              preview_index={safe_idx}
              preview_count={preview_count}
            />

            <.info_bar tincture={focused} />

            <.tincture_dots
              :if={length(@tinctures) > 1}
              tinctures={@tinctures}
              focused_index={@focused_index}
            />
          </div>

          <.side_arrows
            :if={length(@tinctures) > 1}
            focused_index={@focused_index}
            count={length(@tinctures)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Function components — local to this LiveView, no separate module needed
  # ============================================================================

  attr :tincture, :map, required: true
  attr :preview_url, :string, default: nil
  attr :preview_index, :integer, required: true
  attr :preview_count, :integer, required: true

  defp preview_stage(assigns) do
    ~H"""
    <div class="relative w-full max-w-3xl">
      <button
        phx-click="select_tincture"
        phx-value-tincture={@tincture.id}
        class="group relative block aspect-video w-full overflow-hidden rounded-2xl bg-black/40 ring-1 ring-white/10 shadow-2xl transition-all hover:ring-accent-primary/60"
      >
        <%= if @preview_url do %>
          <%!-- Blurred backdrop fill so any letterbox bars look intentional --%>
          <img
            src={@preview_url}
            alt=""
            aria-hidden="true"
            class="absolute inset-0 h-full w-full scale-110 object-cover opacity-60 blur-2xl"
          />
          <%!-- Foreground preview, contained — never cropped regardless of aspect ratio --%>
          <img src={@preview_url} alt="" class="relative h-full w-full object-contain" />
        <% else %>
          <.preview_fallback tincture={@tincture} />
        <% end %>
      </button>

      <%!-- Vertical capsule on the right edge: ↑ / counter / ↓ --%>
      <%= if @preview_count > 1 do %>
        <div
          class="absolute right-4 top-1/2 z-10 flex -translate-y-1/2 flex-col items-stretch overflow-hidden rounded-full border border-white/15 bg-black/55 text-white/90 shadow-lg backdrop-blur-md"
          role="group"
          aria-label="Preview navigation"
        >
          <button
            phx-click="prev_preview"
            class="flex h-9 w-9 items-center justify-center transition-colors hover:bg-white/10 hover:text-white"
            title="Previous preview (↑)"
            aria-label="Previous preview"
          >
            <svg
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2.5"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="m4.5 15.75 7.5-7.5 7.5 7.5" />
            </svg>
          </button>
          <span class="h-px w-full bg-white/15" aria-hidden="true"></span>
          <span class="flex h-7 w-9 items-center justify-center text-[11px] font-medium tabular-nums text-white/80">
            {@preview_index + 1}/{@preview_count}
          </span>
          <span class="h-px w-full bg-white/15" aria-hidden="true"></span>
          <button
            phx-click="next_preview"
            class="flex h-9 w-9 items-center justify-center transition-colors hover:bg-white/10 hover:text-white"
            title="Next preview (↓)"
            aria-label="Next preview"
          >
            <svg
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2.5"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
            </svg>
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :tincture, :map, required: true

  defp preview_fallback(assigns) do
    assigns =
      assign(assigns,
        gradient: gradient_for(assigns.tincture),
        initial: first_letter(assigns.tincture)
      )

    ~H"""
    <div class="flex h-full w-full items-center justify-center" style={"background: " <> @gradient}>
      <%= cond do %>
        <% @tincture.icon_url -> %>
          <img
            src={@tincture.icon_url}
            alt=""
            class="h-48 w-48 select-none object-contain drop-shadow-2xl"
          />
        <% @tincture.icon_emoji -> %>
          <span class="select-none text-[10rem] leading-none drop-shadow-2xl">
            {@tincture.icon_emoji}
          </span>
        <% true -> %>
          <span class="select-none text-[12rem] font-extralight leading-none text-white/90 drop-shadow-2xl">
            {@initial}
          </span>
      <% end %>
    </div>
    """
  end

  attr :tincture, :map, required: true

  defp info_bar(assigns) do
    assigns = assign(assigns, :initial, first_letter(assigns.tincture))

    ~H"""
    <div class="flex w-full max-w-3xl items-center gap-4">
      <%!-- Small icon tile (image > emoji > first letter) --%>
      <div class="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-surface-raised ring-1 ring-white/10">
        <%= cond do %>
          <% @tincture.icon_url -> %>
            <img src={@tincture.icon_url} alt="" class="h-full w-full object-contain" />
          <% @tincture.icon_emoji -> %>
            <span class="text-2xl leading-none">{@tincture.icon_emoji}</span>
          <% true -> %>
            <span class="text-lg font-semibold text-text-secondary">{@initial}</span>
        <% end %>
      </div>

      <%!-- Title + tagline --%>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span class="truncate text-base font-semibold text-text-primary">{@tincture.name}</span>
          <span
            data-tincture-visibility={visibility_label(@tincture.public)}
            class={[
              "shrink-0 rounded px-1.5 py-0.5 text-xs font-medium",
              case @tincture.public do
                true -> "bg-green-500/15 text-green-500"
                false -> "bg-yellow-500/15 text-yellow-500"
                :unknown -> "bg-surface-raised text-text-muted"
              end
            ]}
          >
            {visibility_label(@tincture.public)}
          </span>
        </div>
        <div :if={@tincture.tagline || @tincture.title} class="truncate text-xs text-text-muted">
          {@tincture.tagline || @tincture.title}
        </div>
      </div>

      <%!-- Action buttons --%>
      <div class="flex shrink-0 gap-2">
        <button
          phx-click="select_tincture"
          phx-value-tincture={@tincture.id}
          class="rounded-lg bg-accent-primary px-4 py-1.5 text-xs font-medium text-white transition-colors hover:bg-accent-hover"
        >
          Launch
        </button>
        <button
          phx-click="toggle_visibility"
          phx-value-tincture={@tincture.id}
          disabled={@tincture.public == :unknown}
          title={if @tincture.public == :unknown, do: "Visibility can't be read right now"}
          class="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-50"
        >
          {case @tincture.public do
            true -> "Make Private"
            false -> "Make Public"
            :unknown -> "Visibility unavailable"
          end}
        </button>
        <button
          phx-click="copy_url"
          phx-value-tincture={@tincture.id}
          class="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary"
          title="Copy public URL"
        >
          Copy URL
        </button>
        <button
          phx-click="open_report"
          phx-value-tincture={@tincture.id}
          class="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-red-400 hover:border-red-900"
          title="Report this tincture to cyfr.run moderators"
        >
          Report
        </button>
      </div>
    </div>
    """
  end

  attr :tinctures, :list, required: true
  attr :focused_index, :integer, required: true

  defp tincture_dots(assigns) do
    ~H"""
    <div class="flex items-center">
      <%!-- Each dot sits in a 24 CSS px touch target: the handheld
           viewport's smallest control (tests/browser/handheld.mjs). --%>
      <%= for {_t, i} <- Enum.with_index(@tinctures) do %>
        <button
          phx-click="focus_tincture"
          phx-value-index={i}
          class="flex h-6 min-w-6 items-center justify-center px-0.5"
          aria-label={"Tincture #{i + 1} of #{length(@tinctures)}"}
        >
          <span class={[
            "block rounded-full transition-all duration-300",
            if(i == @focused_index,
              do: "h-1.5 w-6 bg-accent-primary",
              else: "h-1.5 w-1.5 bg-text-muted/30 hover:bg-text-muted/50"
            )
          ]}></span>
        </button>
      <% end %>
    </div>
    """
  end

  attr :focused_index, :integer, required: true
  attr :count, :integer, required: true

  defp side_arrows(assigns) do
    ~H"""
    <button
      phx-click="focus_tincture"
      phx-value-index={@focused_index - 1}
      disabled={@focused_index == 0}
      class="absolute left-6 top-1/2 z-10 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded-full bg-surface-overlay/70 text-text-secondary backdrop-blur-md transition-all hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
      title="Previous tincture (←)"
    >
      <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5 8.25 12l7.5-7.5" />
      </svg>
    </button>
    <button
      phx-click="focus_tincture"
      phx-value-index={@focused_index + 1}
      disabled={@focused_index >= @count - 1}
      class="absolute right-6 top-1/2 z-10 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded-full bg-surface-overlay/70 text-text-secondary backdrop-blur-md transition-all hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
      title="Next tincture (→)"
    >
      <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
      </svg>
    </button>
    """
  end

  defp refresh_corner(assigns) do
    ~H"""
    <button
      phx-click="refresh_tinctures"
      class="absolute right-6 top-6 z-10 rounded-lg p-2 text-text-muted transition-colors hover:bg-surface-raised hover:text-text-secondary"
      title="Refresh tinctures"
      aria-label="Refresh tinctures"
    >
      <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182"
        />
      </svg>
    </button>
    """
  end

  defp picker_empty_state(assigns) do
    ~H"""
    <div class="flex h-full flex-col items-center justify-center gap-3 text-text-muted">
      <.icon name="grid" class="w-12 h-12 opacity-20" />
      <p class="text-sm">No tinctures installed</p>
      <p class="text-xs text-text-muted/70">
        Run <code class="font-mono">cyfr build compile &lt;path&gt;</code> to add one.
      </p>
    </div>
    """
  end
end
