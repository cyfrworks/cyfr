# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  @moduledoc """
  The Prism shell: the tincture picker, the canvas and the system layer.

  The picker is preview-first: a large 16:9 preview stage with vertical
  capsule navigation, a compact info bar and keyboard navigation (←/→
  tinctures, ↑/↓ previews, Enter launches). Launching a tincture opens its
  frame as the active full frame above everything the canvas draws;
  closing it, from inside the tincture or through its capsule, shows the
  next open one or returns to the picker.

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
  or that would raise a hidden frame, is dropped and counted. When a
  frame freezes or goes live again the view pushes `frame_state`, which
  the canvas hook relays to the frame's bridge.

  Every credential this view minted is revoked on each path that ends it:
  `terminate/2` (the socket closed, the person navigated away, the view
  redirected) and the archived-athanor notice before it redirects. A new
  socket is a new open: nothing minted under an earlier one carries over.
  """

  require Logger

  alias Prism.Frames
  alias Sanctum.TinctureAuth

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
      |> assign(:arrangement, nil)
      |> assign(:tinctures, [])
      |> assign(:focused_index, 0)
      |> assign(:current_preview_index, 0)

    socket =
      if connected?(socket) do
        # Subscribe to archive notifications so the shell stops using
        # a context whose athanor is no longer active.
        ctx = socket.assigns.context

        if ctx.athanor_id do
          actor = Sanctum.Context.actor(ctx)
          Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
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

  def handle_event("keynav", %{"key" => key}, socket) do
    {:noreply, handle_keynav(socket, key)}
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
      {:ok, bearer, frames} -> {:reply, %{credential: bearer}, assign(socket, :frames, frames)}
      :error -> {:reply, %{error: "no_credential"}, socket}
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
    if Frames.active(socket.assigns.frames) do
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

  defp close_active_tincture(socket) do
    case Frames.active(socket.assigns.frames) do
      nil -> socket
      %{key: key} -> frames(socket, &Frames.discard(socket.assigns.context, &1, key))
    end
  end

  # Every change to the frames goes through here, so each frame whose
  # state moved between live and frozen is signalled after the credential
  # transition that moved it.
  defp frames(socket, fun) do
    before = socket.assigns.frames
    later = fun.(before)

    Enum.reduce(
      Frames.signals(before, later),
      assign(socket, :frames, later),
      &push_event(&2, "frame_state", &1)
    )
  end

  # ============================================================================
  # Shell verbs
  # ============================================================================

  defp shell_verb(socket, %{key: key}, %{verb: :close}),
    do: frames(socket, &Frames.discard(socket.assigns.context, &1, key))

  # A frame never raises itself: `focus` from a frame already shown asks
  # for nothing, and from a hidden one it is dropped.
  defp shell_verb(socket, %{visible: true}, %{verb: :focus}), do: socket
  defp shell_verb(socket, _frame, %{verb: :focus}), do: drop_message(socket)
  defp shell_verb(socket, _frame, %{verb: :ready}), do: socket

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
    %{context: ctx, tinctures: cards, arrangement: arrangement} = socket.assigns

    frames(socket, fn frames ->
      frames = Frames.prune(ctx, frames, cards)
      if arrangement, do: Frames.arrange(ctx, frames, arrangement, cards), else: frames
    end)
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
  # exactly the frames it places.
  def handle_info({PrismWeb.CanvasLive, :arrangement, arrangement}, socket) do
    %{context: ctx, tinctures: cards} = socket.assigns

    {:noreply,
     socket
     |> assign(:arrangement, arrangement)
     |> frames(&Frames.arrange(ctx, &1, arrangement, cards))}
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
      <%!-- Picker (visible when no tincture is active) --%>
      <div
        :if={Frames.active(@frames) == nil}
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
      />

      <.live_component module={PrismWeb.SystemLayer} id="system-layer" context={@context} />

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
              "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium",
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
    <div class="flex items-center gap-1.5">
      <%= for {_t, i} <- Enum.with_index(@tinctures) do %>
        <button
          phx-click="focus_tincture"
          phx-value-index={i}
          class={[
            "rounded-full transition-all duration-300",
            if(i == @focused_index,
              do: "h-1.5 w-6 bg-accent-primary",
              else: "h-1.5 w-1.5 bg-text-muted/30 hover:bg-text-muted/50"
            )
          ]}
          aria-label={"Tincture #{i + 1} of #{length(@tinctures)}"}
        >
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
