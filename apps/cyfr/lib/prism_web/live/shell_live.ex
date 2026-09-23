# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  @moduledoc """
  Tincture browser for Prism shell — preview-first picker.

  Large 16:9 preview stage with vertical
  capsule navigation, compact info bar, keyboard nav (←/→ tinctures, ↑/↓
  previews, Enter launches). When a tincture is launched the iframe overlays
  the picker; close from inside the tincture or via the top-right capsule
  returns to the picker.

  Sandboxed tinctures communicate with the platform via the PostMessage bridge
  (IframeBridge hook + cyfr.js SDK). Tinctures can invoke backend components
  declared in their manifest dependencies via `cyfr.invoke()`.
  """

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Tinctures")
      |> assign(:active_nav, "tinctures")
      |> assign(:active_tincture, nil)
      |> assign(:opened_tinctures, [])
      |> assign(:tinctures, [])
      |> assign(:focused_index, 0)
      |> assign(:current_preview_index, 0)

    socket =
      if connected?(socket) do
        # Subscribe to archive notifications so the shell stops using
        # a context whose athanor is no longer active.
        ctx = socket.assigns.context

        if ctx.athanor_id do
          Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))
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
    lv = self()
    scan_key = Arca.Cache.Keys.tincture_scan_running(Sanctum.Context.actor(ctx))

    case Arca.Cache.get(scan_key) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "A refresh is already running")}

      :miss ->
        Arca.Cache.put(scan_key, true, :timer.seconds(60))
        logger_metadata = Cyfr.LoggerContext.capture()

        Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
          Cyfr.LoggerContext.restore(logger_metadata)

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

          send(lv, :tinctures_refreshed)
        end)

        {:noreply, put_flash(socket, :info, "Refreshing tinctures…")}
    end
  end

  def handle_event("copy_url", %{"tincture" => tincture_id}, socket) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id))

    if tincture do
      # The public address: the one origin plus the tincture's path.
      url =
        EmissaryWeb.Endpoint.url() <>
          Cyfr.TinctureHelpers.tincture_path(
            tincture.athanor_segment,
            tincture.publisher,
            tincture.name
          )

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
          if tincture.public do
            "Unpublish by revoking the public profile (profile.revoke)."
          else
            "Publish through the consent walk: profile.publish on this " <>
              "tincture's owner profile."
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
          Cyfr.ComponentRef.build(
            "tincture",
            tincture.publisher,
            tincture.name,
            tincture.version
          )

        PrismWeb.ReportComponent.open("report", ref)
        {:noreply, socket}
    end
  end

  def handle_event("iframe_message", %{"window_id" => window_id, "message" => msg}, socket) do
    handle_iframe_message(socket, window_id, msg)
  end

  def handle_event("iframe_message", _params, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Tracking + loading
  # ============================================================================

  defp maybe_track_tincture(socket, tincture_id) do
    if tincture_id in socket.assigns.opened_tinctures do
      socket
    else
      assign(socket, :opened_tinctures, socket.assigns.opened_tinctures ++ [tincture_id])
    end
  end

  defp handle_keynav(socket, "ArrowLeft"),
    do: focus_tincture(socket, socket.assigns.focused_index - 1)

  defp handle_keynav(socket, "ArrowRight"),
    do: focus_tincture(socket, socket.assigns.focused_index + 1)

  defp handle_keynav(socket, "ArrowUp"), do: cycle_preview(socket, -1)
  defp handle_keynav(socket, "ArrowDown"), do: cycle_preview(socket, +1)

  defp handle_keynav(socket, "Enter") do
    if socket.assigns.active_tincture do
      socket
    else
      case Enum.at(socket.assigns.tinctures, socket.assigns.focused_index) do
        nil -> socket
        tincture -> launch_tincture(socket, tincture.id)
      end
    end
  end

  defp handle_keynav(socket, "Escape") do
    if socket.assigns.active_tincture, do: close_active_tincture(socket), else: socket
  end

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
    socket
    |> assign(:active_tincture, tincture_id)
    |> maybe_track_tincture(tincture_id)
  end

  defp close_active_tincture(socket) do
    active = socket.assigns.active_tincture
    opened = List.delete(socket.assigns.opened_tinctures, active)
    new_active = List.first(opened)

    socket
    |> assign(:opened_tinctures, opened)
    |> assign(:active_tincture, new_active)
  end

  defp load_tinctures(socket) do
    ctx = socket.assigns.context

    # Use the cached registry, which scans lazily and follows tincture
    # change notifications. The refresh button forces a rescan.
    tinctures =
      Prism.TinctureRegistry.list_tinctures(ctx)
      |> Enum.map(fn t ->
        ref = Cyfr.ComponentRef.build("tincture", t.publisher, t.name)
        access = mint_access(socket, t)

        public =
          case Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref) do
            {:ok, profiles} ->
              Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))

            _ ->
              false
          end

        %{
          id: "iframe_#{t.name}",
          name: t.name,
          publisher: t.publisher,
          athanor_id: t.athanor_id,
          athanor_segment: t.athanor_segment,
          version: t.version,
          title: t.title,
          tagline: t.tagline,
          icon: t.icon,
          icon_url: build_asset_url(access, t, t.media_icon),
          icon_emoji: emoji_from_hint(t.icon),
          preview_urls:
            t.media_previews
            |> Enum.map(&build_asset_url(access, t, &1))
            |> Enum.reject(&is_nil/1),
          url: build_tincture_url(access, t),
          url_refusal: refusal(access),
          manifest: t.manifest,
          public: public
        }
      end)

    # Clamp focused_index if the list shrank, reset preview cursor.
    focused = min(socket.assigns.focused_index || 0, max(length(tinctures) - 1, 0))

    socket
    |> assign(:tinctures, tinctures)
    |> assign(:focused_index, focused)
    |> assign(:current_preview_index, 0)
  end

  # One short-lived, single-purpose access token per tincture instead of
  # the raw session token — a credential must never travel in a
  # URL/query string — scoped to this tincture, because the sandboxed frame
  # can read it back out of its own location and send it wherever its
  # manifest allows. The page, its icon and its previews share it.
  defp mint_access(socket, t),
    do: Sanctum.TinctureAuth.issue_access_token(socket.assigns.context, t.publisher, t.name)

  # A mint that did not happen renders as a state, never as a URL.
  defp refusal({:ok, _token}), do: nil
  defp refusal({:error, reason}) when reason in [:unavailable, :not_owner], do: :unavailable
  defp refusal({:error, _reason}), do: :refused

  # Same origin as the shell itself: a relative path, so the iframe is
  # never cross-origin whatever hostname or proxy the browser came in through.
  defp build_tincture_url({:ok, token}, t) do
    base = Cyfr.TinctureHelpers.tincture_path(t.athanor_segment, t.publisher, t.name)
    "#{base}?_t=#{token}"
  end

  defp build_tincture_url({:error, _reason}, _t), do: nil

  # Build a same-origin asset URL for icons/previews. Returns nil for missing
  # paths or non-image extensions — server-side validators in
  # `Cyfr.TinctureHelpers.serve_asset/4` re-check everything; this is a fast
  # client-side reject so we don't emit obviously broken URLs.
  # Derived from the serve gate: the fast client-side reject and the
  # server-side validators answer from one roster.
  @image_extensions Cyfr.TinctureHelpers.image_extensions()

  defp build_asset_url(_access, _tincture, nil), do: nil
  defp build_asset_url(_access, _tincture, ""), do: nil

  defp build_asset_url({:ok, token}, t, path) when is_binary(path) do
    if safe_asset_path?(path) do
      encoded = path |> String.split("/") |> Enum.map_join("/", &URI.encode/1)

      base =
        Cyfr.TinctureHelpers.tincture_path(t.athanor_segment, t.publisher, t.name) <>
          "/" <> encoded

      "#{base}?_t=#{token}"
    end
  end

  defp build_asset_url(_access, _tincture, _), do: nil

  defp safe_asset_path?(path) do
    ext = path |> Path.extname() |> String.downcase()

    Cyfr.PathSafety.validate_relative_path(path) == :ok and ext in @image_extensions
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

  # ============================================================================
  # iframe message handling
  # ============================================================================

  defp handle_iframe_message(socket, window_id, %{"type" => "cyfr:request"} = msg) do
    # Normalize untrusted iframe payloads to maps before reading fields.
    msg = Map.put(msg, "payload", payload_map(msg["payload"]))

    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == window_id))

    if tincture do
      case msg["action"] do
        "invoke" ->
          handle_invoke(socket, window_id, tincture, msg)

        "set_title" ->
          tinctures =
            Enum.map(socket.assigns.tinctures, fn t ->
              if t.id == window_id,
                do: Map.put(t, :title, msg["payload"]["title"] || t.title),
                else: t
            end)

          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}

          {:noreply,
           socket
           |> assign(:tinctures, tinctures)
           |> push_event("iframe_response:#{window_id}", response)}

        "close" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          socket = push_event(socket, "iframe_response:#{window_id}", response)

          opened = List.delete(socket.assigns.opened_tinctures, window_id)

          active =
            if socket.assigns.active_tincture == window_id do
              List.first(opened)
            else
              socket.assigns.active_tincture
            end

          {:noreply,
           socket
           |> assign(:opened_tinctures, opened)
           |> assign(:active_tincture, active)}

        "ready" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

        "get_context" ->
          response = %{
            type: "cyfr:response",
            id: msg["id"],
            result: %{tincture_id: tincture.id, window_id: window_id}
          }

          {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

        _ ->
          error_response = %{
            type: "cyfr:response",
            id: msg["id"],
            error: "unknown_action"
          }

          {:noreply, push_event(socket, "iframe_response:#{window_id}", error_response)}
      end
    else
      if msg["id"] do
        response = %{type: "cyfr:response", id: msg["id"], error: "window_not_found"}
        {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
      else
        {:noreply, socket}
      end
    end
  end

  defp handle_iframe_message(socket, _window_id, _msg), do: {:noreply, socket}

  # A payload that is not an object carries no keys, so it reads as the empty
  # one — the handlers then take their own "missing field" paths (keep the
  # current title, refuse an invoke with no reference) instead of raising.
  defp payload_map(%{} = payload), do: payload
  defp payload_map(_other), do: %{}

  # The HTTP invoke route carries TinctureRateLimit keyed by IP; this is the
  # same capability reached from a LiveView socket, keyed by person instead.
  # The two are deliberately separate budgets, not one shared one — the keys
  # differ, so a signed-in person has a full budget here and there. Same
  # limiter table, same bucket vocabulary, same config override, and the
  # default number comes from the plug so the two cannot drift.
  defp invoke_throttled?(ctx, tincture) do
    max = Cyfr.RuntimeConfig.tincture_invoke_max()

    key = {:rate_limit, :invoke, {:live, ctx.user_id}, tincture.publisher, tincture.name}

    match?(
      {:deny, _},
      Cyfr.RateLimiter.check(key, max, Cyfr.RuntimeConfig.tincture_rate_window_ms())
    )
  end

  defp handle_invoke(socket, window_id, tincture, msg) do
    reference = get_in(msg, ["payload", "reference"])
    input = get_in(msg, ["payload", "input"]) || %{}

    if invoke_throttled?(socket.assigns.context, tincture) do
      response = %{type: "cyfr:response", id: msg["id"], error: "rate limited — retry shortly"}
      {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
    else
      # One implementation for both invoke surfaces (the HTTP route is the
      # other) — validation, context, logging, telemetry and the readiness
      # gate live in Emissary.Tincture.Invoke. Before the extraction this
      # surface emitted no telemetry, so console invocations were invisible
      # to the activity feed. The console shell is an owner surface: the
      # protected-route profile roots the invocation whatever the
      # tincture's public visibility, and there is no client IP to pass —
      # the socket authenticated the person instead.
      result =
        Emissary.Tincture.Invoke.run(socket.assigns.context, tincture, reference, input,
          route: :protected,
          method: "LIVE /shell/invoke"
        )

      response =
        case result do
          {:ok, ok} ->
            %{type: "cyfr:response", id: msg["id"], result: ok}

          {:error, :consent_required, message} ->
            %{type: "cyfr:response", id: msg["id"], error: "consent_required: " <> message}

          {:error, _code, message} ->
            %{type: "cyfr:response", id: msg["id"], error: message}
        end

      {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
    end
  end

  # Build a scoped execution context for tincture invoke.
  # Preserves the operator's user_id for audit trails, but limits
  # permissions to [:execute] only. Guards against nil fields to
  # satisfy NOT NULL constraints on execution_records.
  # Tincture execution context is built by `Sanctum.build_tincture_context/2`
  # (single source of truth, shared with the tincture controller).

  @impl true
  def handle_info({:report_component, :submitted}, socket) do
    {:noreply, put_flash(socket, :info, "Report submitted. Thanks.")}
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
  def handle_info({:notify, athanor_id, :athanor_changed, _payload}, socket) do
    ctx = socket.assigns.context

    if athanor_id == ctx.athanor_id and not Sanctum.Tenancy.Athanors.active?(athanor_id) do
      {:noreply,
       socket
       |> put_flash(:error, "This athanor was archived.")
       |> redirect(to: "/")}
    else
      {:noreply, socket}
    end
  end

  # Other tray traffic on the athanor's topic is for the topbar, not the shell.
  def handle_info({:notify, _athanor_id, _kind, _payload}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
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
      <%!-- Iframe overlay — fixed to cover entire viewport including sidebar --%>
      <%= for tincture_id <- @opened_tinctures do %>
        <% tincture = Enum.find(@tinctures, &(&1.id == tincture_id)) %>
        <div
          :if={tincture}
          class={[
            "fixed inset-0 z-50 flex flex-col bg-surface-base",
            if(tincture_id != @active_tincture, do: "hidden")
          ]}
        >
          <iframe
            :if={tincture.url}
            id={"iframe_#{tincture_id}"}
            src={tincture.url}
            sandbox="allow-scripts"
            class="w-full h-full border-0"
            phx-hook="IframeBridge"
            data-window-id={tincture_id}
          />
          <div
            :if={is_nil(tincture.url)}
            id={"tincture_state_#{tincture_id}"}
            data-tincture-state={tincture.url_refusal}
            class="flex h-full w-full items-center justify-center text-sm text-text-muted"
          >
            {if tincture.url_refusal == :unavailable,
              do: "This tincture can't be opened right now. Try again shortly.",
              else: "Your session can no longer open this tincture. Sign in again."}
          </div>
          <.iframe_capsule />
        </div>
      <% end %>

      <%!-- Picker (visible when no tincture is active) --%>
      <div :if={@active_tincture == nil} class="absolute inset-0 z-10 flex h-full flex-col">
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
        module={PrismWeb.ReportComponent}
        id="report"
        ctx={@context}
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
          <span class={[
            "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium",
            if(@tincture.public,
              do: "bg-green-500/15 text-green-500",
              else: "bg-yellow-500/15 text-yellow-500"
            )
          ]}>
            {if @tincture.public, do: "public", else: "private"}
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
          class="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary"
        >
          {if @tincture.public, do: "Make Private", else: "Make Public"}
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
end
