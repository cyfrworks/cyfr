# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  @moduledoc """
  The Prism shell: the desktop, the canvas, the system layer and, when no
  desktop runs, the tincture picker.

  ## The desktop

  The shell opens the desktop tincture the person's layout names for the
  posture (`tincture:local.desktop` when they never arranged one) as a
  frame placed `:desktop`, under every slot and floating frame and filling
  the canvas, through `Prism.Frames` like any frame. A layout published
  anywhere for this person (`Cyfr.Bus.LayoutPublished` on their own
  topic) is read again, and the frames follow it.

  A desktop that has not sent `ready` within ten seconds of taking its
  credential, one whose frame is refused at open, and the person's own
  ask — the shell's `Safe mode` button or Ctrl+Alt+S on the shell's page,
  never a frame's message — enter safe mode: every frame is discarded
  with its credential, the system layer shows the safe mode prompt
  (`Prism.SafeMode`), and the picker is drawn. The prompt's confirmation
  leaves safe mode and opens the desktop from the layout as it then
  stands. The assistant's panel is not the shell's and is untouched.

  The picker is preview-first: a large 16:9 preview stage with vertical
  capsule navigation, a compact info bar and keyboard navigation (←/→
  tinctures, ↑/↓ previews, Enter launches). It is drawn in safe mode and
  when the layout's desktop is not installed. Launching a tincture opens
  its frame as the active full frame above everything the canvas draws;
  closing it, from inside the tincture or through its capsule, shows the
  next open one or returns to the desktop.

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
  the shell holds the frames that arrangement places. The system layer
  (`PrismWeb.SystemLayer`) is mounted above them.

  The `IframeBridge` hook hands a frame a `MessagePort` on its first load,
  and the frame credential over that port only (`frame_handshake`,
  answered once per frame). The frame's SDK sends data to the endpoint
  under that bearer; the port carries the shell verbs of
  `Prima.TinctureWire`, which reach this view as `frame_verb`. A message
  that does not decode, that names a frame this view does not hold live,
  or that asks for what its frame may not, is dropped and counted; no
  verb places, sizes or raises a frame. When a
  frame freezes or goes live again the view pushes `frame_state`, which
  the canvas hook relays to the frame's bridge.

  While a full frame is shown it covers everything under it, so the
  shell sets `covered`: the layout takes its chrome (the top bar, the
  sidebar and the drawer) out of reach with `inert`, and the canvas does
  the same to every layer under the full frame. The full frame and its
  capsule, the shell's Safe mode control, the system layer and the
  assistant's panel stay reachable.

  Every credential this view minted is revoked on each path that ends it:
  `terminate/2` (the socket closed, the person navigated away, the view
  redirected) and the archived-athanor notice before it redirects. A new
  socket is a new open: nothing minted under an earlier one carries over.
  """

  require Logger

  alias Prism.Frames
  alias Prism.SafeMode
  alias Sanctum.TinctureAuth

  # How long a desktop has, from its handshake, to send `ready` before the
  # shell enters safe mode.
  @desktop_ready_ms 10_000

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Tinctures")
      |> assign(:active_nav, "tinctures")
      |> assign(:frames, Frames.new())
      |> assign(:covered, false)
      |> assign(:arrangement, nil)
      |> assign(:desktop, :pending)
      |> assign(:desktop_ready, nil)
      |> assign(:safe_mode, nil)
      |> assign(:credential_prompts, %{})
      |> assign(:grant_prompts, %{})
      |> assign(:pairing_prompt, nil)
      |> assign(:prompt_seq, 0)
      |> assign(:tinctures, [])
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
      # The public address: the one origin plus the tincture's path.
      url =
        CyfrWeb.Endpoint.url() <>
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
  # load, and posts it over the port it hands the frame. The bearer leaves
  # this process once: a second ask — a reload, a navigation inside the
  # frame, another script on the page — is answered with nothing.
  def handle_event("frame_handshake", %{"frame" => frame_id}, socket) do
    case Frames.hand_over(socket.assigns.frames, frame_id) do
      {:ok, bearer, frames} ->
        arm_desktop_deadline(frames, frame_id)
        {:reply, %{credential: bearer}, assign(socket, :frames, frames)}

      :error ->
        {:reply, %{error: "no_credential"}, socket}
    end
  end

  def handle_event("frame_handshake", _params, socket),
    do: {:reply, %{error: "no_credential"}, socket}

  # A shell verb the frame posted over its port. The bridge names the frame
  # whose port it came from, and the message must name the same one.
  def handle_event("frame_verb", %{"frame" => frame_id, "message" => message}, socket)
      when is_binary(frame_id) do
    with {:ok, %{frame: ^frame_id} = decoded} <- Prima.TinctureWire.decode_shell_message(message),
         {:ok, frame} <- Frames.attribute(socket.assigns.frames, frame_id) do
      {:noreply, shell_verb(socket, frame, decoded)}
    else
      _ -> {:noreply, drop_message(socket)}
    end
  end

  def handle_event("frame_verb", _params, socket), do: {:noreply, drop_message(socket)}

  # The person asked for safe mode through the shell's own chrome: its
  # button, or the chord the canvas hook hears on the shell's page.
  def handle_event("safe_mode", _params, socket),
    do: {:noreply, enter_safe_mode(socket, :requested)}

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

  # No tincture runs while safe mode is on.
  defp launch_tincture(%{assigns: %{safe_mode: %{}}} = socket, _tincture_id), do: socket

  defp launch_tincture(socket, tincture_id) do
    case Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id)) do
      nil -> socket
      card -> frames(socket, &Frames.launch(socket.assigns.context, &1, card))
    end
  end

  defp close_active_tincture(socket) do
    case Frames.active(socket.assigns.frames) do
      nil -> socket
      %{key: key} -> frames(socket, &Frames.discard(socket.assigns.context, &1, key))
    end
  end

  # Every change to the frames goes through here, so each frame whose
  # state moved between live and frozen is signalled after the credential
  # transition that moved it, and each frame newly refused for want of a
  # grant is offered the grant prompt.
  defp frames(socket, fun) do
    before = socket.assigns.frames
    later = fun.(before)

    socket =
      Enum.reduce(
        Frames.signals(before, later),
        assign(socket, frames: later, covered: Frames.active(later) != nil),
        &push_event(&2, "frame_state", &1)
      )

    ungranted =
      for %{state: :refused, refusal: :ungranted, id: id} = frame <- Frames.list(later),
          not match?(%{id: ^id}, Frames.get(before, frame.key)),
          do: frame

    Enum.reduce(ungranted, socket, &offer_grant(&2, &1))
  end

  # ============================================================================
  # Shell verbs
  # ============================================================================

  defp shell_verb(socket, %{key: key}, %{verb: :close}),
    do: frames(socket, &Frames.discard(socket.assigns.context, &1, key))

  # The desktop's `ready` is what keeps the shell out of safe mode; any
  # other frame's asks for nothing.
  defp shell_verb(socket, %{placement: :desktop, id: id}, %{verb: :ready}),
    do: assign(socket, :desktop_ready, id)

  defp shell_verb(socket, _frame, %{verb: :ready}), do: socket

  # A secret is typed into the shell's own prompt, never into a frame, and
  # only for a frame the person can see whose version declares the vault
  # write the prompt makes. One prompt per frame at a time.
  defp shell_verb(socket, %{id: id, visible: true} = frame, %{
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

  defp shell_verb(socket, _frame, %{verb: :credential}), do: drop_message(socket)

  defp shell_verb(socket, %{tincture_id: tincture_id}, %{
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
  defp shell_verb(socket, _frame, %{verb: :open, args: %{"ref" => ref}}) do
    with {:ok, parsed} <- Prima.ComponentRef.parse(ref),
         %{id: id} <- Enum.find(socket.assigns.tinctures, &lists?(&1, parsed)) do
      launch_tincture(socket, id)
    else
      _ -> drop_message(socket)
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
  # The desktop and safe mode
  # ============================================================================

  # Hold the frames the arrangement places and the desktop it names. A
  # desktop that is not installed holds none, and the picker is drawn; one
  # whose frame is refused at open is safe mode.
  defp place(%{assigns: %{safe_mode: %{}}} = socket), do: socket
  defp place(%{assigns: %{arrangement: nil}} = socket), do: socket

  defp place(socket) do
    %{context: ctx, tinctures: cards, arrangement: arrangement} = socket.assigns

    case Frames.resolve(arrangement.desktop, cards) do
      nil ->
        socket
        |> frames(fn frames ->
          frames = Frames.arrange(ctx, frames, arrangement, cards)

          case Frames.desktop(frames) do
            %{key: key} -> Frames.discard(ctx, frames, key)
            nil -> frames
          end
        end)
        |> assign(:desktop, :none)

      card ->
        socket =
          socket
          |> frames(fn frames ->
            Frames.open_desktop(ctx, Frames.arrange(ctx, frames, arrangement, cards), card)
          end)
          |> assign(:desktop, card.id)

        case Frames.desktop(socket.assigns.frames) do
          %{state: :refused} -> enter_safe_mode(socket, :not_ready)
          _held -> socket
        end
    end
  end

  # The deadline starts when the desktop takes its credential, the moment
  # its page can first speak.
  defp arm_desktop_deadline(frames, frame_id) do
    case Frames.desktop(frames) do
      %{id: ^frame_id} ->
        Process.send_after(self(), {:desktop_deadline, frame_id}, @desktop_ready_ms)

      _other ->
        :ok
    end
  end

  # Safe mode: every frame is discarded with its credential and the system
  # layer offers the ways out; the picker is drawn meanwhile.
  defp enter_safe_mode(%{assigns: %{safe_mode: %{}}} = socket, _reason), do: socket

  defp enter_safe_mode(socket, reason) do
    ctx = socket.assigns.context
    {prompt_id, socket} = next_prompt_id(socket, "safe-mode")

    show_prompt(%{
      id: prompt_id,
      kind: :safe_mode,
      action: nil,
      subject: SafeMode.enter(reason, layout_as_read(ctx))
    })

    socket
    |> assign(:frames, Frames.clear(ctx, socket.assigns.frames))
    |> assign(:covered, false)
    |> assign(:safe_mode, %{id: prompt_id, reason: reason})
    |> assign(:desktop_ready, nil)
    |> assign(:credential_prompts, %{})
    |> assign(:grant_prompts, %{})
  end

  # The layout safe mode is entered over: the document and revision read
  # now. A layout that cannot be read is entered over the shipped default
  # at revision 0, so the default is still offered; publishing it over a
  # layout the person has is refused as stale, and nothing is merged.
  defp layout_as_read(ctx) do
    case Compendium.layout(ctx, hd(Prima.Layout.postures())) do
      {:ok, layout} -> layout
      {:error, _refusal} -> %{document: Prima.Layout.default(), revision: 0}
    end
  end

  # The person chose: the desktop runs again from the layout as it stands.
  defp leave_safe_mode(socket) do
    send_update(PrismWeb.CanvasLive, id: "canvas", reload: true)
    assign(socket, safe_mode: nil, desktop: :pending)
  end

  # ============================================================================
  # System layer prompts
  # ============================================================================

  defp show_prompt(prompt),
    do: send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)

  defp next_prompt_id(socket, kind) do
    seq = socket.assigns.prompt_seq + 1
    {"#{kind}-#{seq}", assign(socket, :prompt_seq, seq)}
  end

  # A frame refused because the person has not granted what its tincture
  # declares now: the grant prompt, whose sheet draws the preview's rows,
  # the tincture's frame, streams, cards and system actions among them,
  # and binds the vault entries it needs, when the consent walk's plan and
  # preview can be read for it (`PrismWeb.SystemLayer.grant_prompt/4`).
  # Otherwise the frame shows its refusal.
  defp offer_grant(socket, %{key: key, tincture_id: tincture_id, reference: reference}) do
    ref = Prima.ComponentRef.build("tincture", reference.publisher, reference.name)
    {prompt_id, next} = next_prompt_id(socket, "grant")

    case PrismWeb.SystemLayer.grant_prompt(socket, prompt_id, ref) do
      {:ok, prompt} ->
        show_prompt(prompt)
        update(next, :grant_prompts, &Map.put(&1, prompt_id, {key, tincture_id}))

      {:error, _unavailable} ->
        socket
    end
  end

  # A grant confirmed: the refused frame is opened again where it was.
  defp granted(socket, {key, tincture_id}) do
    %{context: ctx} = socket.assigns
    socket = frames(socket, &Frames.discard(ctx, &1, key))

    case key do
      {:full, _} -> launch_tincture(socket, tincture_id)
      _placed -> place(socket)
    end
  end

  defp prompt_outcome(socket, id, outcome) do
    %{safe_mode: safe_mode, credential_prompts: credentials, grant_prompts: grants} =
      socket.assigns

    cond do
      match?(%{id: ^id}, safe_mode) ->
        if outcome == :confirmed, do: leave_safe_mode(socket), else: socket

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
    socket = update(socket, :grant_prompts, &Map.delete(&1, id))
    if outcome == :confirmed, do: granted(socket, frame), else: socket
  end

  defp load_tinctures(socket) do
    ctx = socket.assigns.context

    # Use the cached registry, which scans lazily and follows tincture
    # change notifications. The refresh button forces a rescan.
    tinctures =
      Prism.TinctureRegistry.list_tinctures(ctx)
      |> Enum.map(fn t ->
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
          preview_urls:
            t.media_previews |> Enum.map(&media_url(media, &1)) |> Enum.reject(&is_nil/1)
        })
      end)

    # Clamp focused_index if the list shrank, reset preview cursor.
    focused = min(socket.assigns.focused_index || 0, max(length(tinctures) - 1, 0))

    socket
    |> assign(:tinctures, tinctures)
    |> assign(:focused_index, focused)
    |> assign(:current_preview_index, 0)
    |> follow_listing()
  end

  # A frame whose tincture the registry no longer lists is discarded with
  # its credential, and the layout's entries are placed again against the
  # new listing.
  defp follow_listing(socket) do
    %{context: ctx, tinctures: cards} = socket.assigns

    socket
    |> frames(&Frames.prune(ctx, &1, cards))
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

  # The picker is for when no desktop runs: safe mode, or a layout whose
  # desktop is not installed or could not be read. It is under an active
  # full frame like everything else.
  defp picker?(%{frames: frames, safe_mode: safe_mode, desktop: desktop}) do
    Frames.active(frames) == nil and (not is_nil(safe_mode) or desktop == :none)
  end

  defp prompting?(%{
         safe_mode: safe_mode,
         credential_prompts: credentials,
         grant_prompts: grants,
         pairing_prompt: pairing
       }),
       do: not is_nil(safe_mode) or credentials != %{} or grants != %{} or not is_nil(pairing)

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

  # The refresh's answer, taken only under the focus it was started for.
  @impl true
  def handle_info({:deliver, tag, message}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &handle_info(message, &1))

  def handle_info({:report_component, :submitted}, socket) do
    {:noreply, put_flash(socket, :info, "Report submitted. Thanks.")}
  end

  # The canvas read the layout for the posture the client reported: hold
  # exactly the frames it places, and the desktop it names.
  def handle_info({PrismWeb.CanvasLive, :arrangement, arrangement}, socket) do
    {:noreply, socket |> assign(:arrangement, arrangement) |> place()}
  end

  # The layout could not be read: no desktop is known, so the picker is
  # drawn until a read succeeds.
  def handle_info({PrismWeb.CanvasLive, :layout_unavailable}, socket) do
    if socket.assigns.desktop == :pending,
      do: {:noreply, assign(socket, :desktop, :none)},
      else: {:noreply, socket}
  end

  # The person's layout was published — by their desktop, the assistant or
  # safe mode's choice, in this session or another: read it again.
  def handle_info(%Cyfr.Bus.LayoutPublished{user_id: user_id}, socket) do
    if user_id == socket.assigns.context.user_id,
      do: send_update(PrismWeb.CanvasLive, id: "canvas", reload: true)

    {:noreply, socket}
  end

  # The desktop took its credential this long ago. Without its `ready` the
  # shell enters safe mode; a desktop hidden meanwhile, whose bridge holds
  # its verbs, has the time again once it is shown.
  def handle_info({:desktop_deadline, frame_id}, socket) do
    %{frames: frames, desktop_ready: ready, safe_mode: safe_mode} = socket.assigns

    case Frames.desktop(frames) do
      %{id: ^frame_id} when ready == frame_id or not is_nil(safe_mode) ->
        {:noreply, socket}

      %{id: ^frame_id, state: :frozen} ->
        Process.send_after(self(), {:desktop_deadline, frame_id}, @desktop_ready_ms)
        {:noreply, socket}

      %{id: ^frame_id} ->
        {:noreply, enter_safe_mode(socket, :not_ready)}

      _another_or_none ->
        {:noreply, socket}
    end
  end

  def handle_info({:system_layer, id, outcome}, socket) when is_binary(id),
    do: {:noreply, prompt_outcome(socket, id, outcome)}

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

  # Every frame credential this view minted is revoked as it ends — the
  # socket closed, the person left or navigated away, the view redirected
  # — revoked ones included, since revoking is idempotent. A view that
  # dies without reaching here leaves each row to its deadline.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx, frames: %Frames{} = frames} ->
        Frames.revoke_all(ctx, frames)
        :ok

      _unmounted ->
        :ok
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="shell"
      class="h-full relative bg-surface-base"
      phx-window-keydown="keynav"
    >
      <%!-- Picker: drawn in safe mode, or when no desktop runs, while no
           tincture is active --%>
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

      <.live_component
        module={PrismWeb.CanvasLive}
        id="canvas"
        context={@context}
        frames={@frames}
        tinctures={@tinctures}
        safe_mode={not is_nil(@safe_mode)}
      />

      <%!-- The shell's own chrome: no frame draws it or reaches it. --%>
      <button
        id="shell-safe-mode"
        type="button"
        phx-click="safe_mode"
        disabled={not is_nil(@safe_mode)}
        aria-keyshortcuts="Control+Alt+S"
        title="Safe mode (Ctrl+Alt+S)"
        class="absolute bottom-2 left-2 z-[55] min-h-6 rounded-md bg-black/60 px-2 py-1 text-xs text-white/80 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-300 disabled:opacity-50"
      >
        Safe mode
      </button>

      <button
        id="shell-devices"
        type="button"
        phx-click="devices"
        data-test="shell-devices"
        title="Pair or revoke a device"
        class="absolute bottom-2 left-24 z-[55] min-h-6 rounded-md bg-black/60 px-2 py-1 text-xs text-white/80 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-300"
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
          ]}>
          </span>
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
