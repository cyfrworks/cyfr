# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActiveContext do
  @moduledoc """
  Single source of truth for "what is the user looking at right now?"

  Pure functions over the LiveView socket — no GenServer, no per-session
  process state. Derives the active context from the URL on every
  `handle_params` callback.

  Single-user dev tool: there is no disconnect-survival concern.
  Reconnects re-derive from the URL.

  ## Phase 1 consumer

  The Cmd+K command palette (`PrismWeb.CommandPaletteLiveComponent`) reads
  `socket.assigns.active_context.focused_resource` to surface contextual
  actions like "Rerun current request" or "Copy current component ref".

  ## Phase 3 consumer

  The AQUA overlay (`PrismWeb.AquaLive`) is `live_render`'d into the
  layout's portal slot, which gives it its own LiveView socket separate
  from the page-level LiveView. It subscribes to
  `prism:active_context:<session_id>` on mount; the page-level LiveView
  broadcasts to that topic on every `handle_params`. The overlay then
  forwards `active_context` as input to `formula:local.aqua` so the
  agent always knows the current page and focused resource.

  ## Wiring

  Hooked via `live_session :on_mount`. Every authenticated LiveView gets
  `socket.assigns.active_context` populated automatically on mount and
  on every subsequent `handle_params`. The same hook also broadcasts to
  the per-session topic for the overlay to consume.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView

  @broadcast_base "prism:active_context"

  @doc """
  PubSub topic used by the overlay to receive context updates for a
  given Phoenix session. Keyed by `session_id` so live_render'd children
  (the overlay) can subscribe by passing through the session.
  """
  def topic(session_id) when is_binary(session_id), do: "#{@broadcast_base}:#{session_id}"

  @type focused_resource ::
          {:request, String.t()}
          | {:execution, String.t()}
          | {:component, String.t()}
          | {:tincture, String.t()}
          | {:log, String.t()}
          | {:schedule, String.t()}
          | nil

  @type snapshot :: %{
          required(:type) => String.t(),
          optional(:items) => [map()],
          optional(:selected_id) => String.t() | nil,
          optional(:total) => non_neg_integer()
        }

  @type t :: %{
          route: String.t() | nil,
          focused_resource: focused_resource(),
          params: map(),
          snapshot: snapshot() | nil
        }

  # ============================================================================
  # on_mount hook — wired in router.ex live_session
  # ============================================================================

  @doc """
  on_mount hook that attaches `active_context` to socket assigns and keeps
  it fresh on every `handle_params`.

  Add to the `:authenticated` live_session:

      live_session :authenticated,
        on_mount: [
          {PrismWeb.LiveAuth, :require_auth},
          {PrismWeb.LiveClaimGate, :require_claim},
          {PrismWeb.ActiveContext, :assign}
        ] do
        ...
      end
  """
  def on_mount(:assign, params, session, socket) do
    socket =
      socket
      |> assign(:active_context, derive(params, nil))
      |> assign(:prism_session_id, session_id_from_session(session))
      |> LiveView.attach_hook(
        :prism_active_context,
        :handle_params,
        &handle_params_hook/3
      )

    {:cont, socket}
  end

  # Stable per-Phoenix-session identifier for the broadcast topic.
  # Hash the session_token so the raw credential never appears in topics
  # (PubSub stays server-internal, but defense-in-depth still beats a
  # cleartext-token suffix). Falls back to the CSRF token for the rare
  # mounts that arrive without a session_token.
  defp session_id_from_session(session) when is_map(session) do
    seed = session["session_token"] || session["_csrf_token"] || ""

    case seed do
      "" -> nil
      bin when is_binary(bin) -> :crypto.hash(:sha256, bin) |> Base.url_encode64(padding: false)
      _ -> nil
    end
  end

  defp session_id_from_session(_), do: nil

  @doc """
  Resolve the same per-session topic key from a session map. Used by
  child LiveViews (e.g. AquaLive) that receive the session at
  mount time and need to subscribe.
  """
  def session_id(session), do: session_id_from_session(session)

  @doc """
  Open the AQUA overlay with `prompt` pre-filled in its composer.

  Returns the socket unchanged — the overlay listens on the per-session
  topic and reacts to the broadcast in `handle_info/2`. Callers use it
  in `handle_event` returns:

      {:noreply, PrismWeb.ActiveContext.seed_aqua(socket, "Help me with X")}

  No-op (returns the socket as-is) when no per-session topic is wired,
  e.g. before the LiveView has fully mounted or in test scaffolds without
  the session hook.
  """
  @spec seed_aqua(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def seed_aqua(%Phoenix.LiveView.Socket{} = socket, prompt) when is_binary(prompt) do
    case socket.assigns[:prism_session_id] do
      sid when is_binary(sid) ->
        Phoenix.PubSub.broadcast(Emissary.PubSub, topic(sid), {:aqua_seed, prompt})

      _ ->
        :ok
    end

    socket
  end

  @doc """
  Attach a page snapshot to the active context and re-broadcast so the AQUA
  overlay sees it. Snapshot describes "what is currently on screen" — a
  small list of items the user is looking at, so the agent can reason
  about the page without making read tool calls.

  Pages opt in from their LiveView after loading data:

      {:noreply, PrismWeb.ActiveContext.set_snapshot(socket,
        %{type: "api_keys", items: keys, total: length(keys)})}

  Caps `items` at 20 entries to keep the agent input small.
  """
  @spec set_snapshot(Phoenix.LiveView.Socket.t(), snapshot()) :: Phoenix.LiveView.Socket.t()
  def set_snapshot(%Phoenix.LiveView.Socket{} = socket, %{} = snap) do
    capped =
      case snap[:items] || snap["items"] do
        items when is_list(items) -> Map.put(snap, :items, Enum.take(items, 20))
        _ -> snap
      end

    current =
      socket.assigns[:active_context] ||
        %{route: nil, focused_resource: nil, params: %{}, snapshot: nil}

    next_ctx = Map.put(current, :snapshot, capped)
    socket = assign(socket, :active_context, next_ctx)
    broadcast_change(socket, next_ctx)
    socket
  end

  defp handle_params_hook(params, uri, socket) do
    ctx = derive(params, uri)
    socket = assign(socket, :active_context, ctx)
    broadcast_change(socket, ctx)
    {:cont, socket}
  end

  defp broadcast_change(socket, ctx) do
    case socket.assigns[:prism_session_id] do
      sid when is_binary(sid) ->
        Phoenix.PubSub.broadcast(Emissary.PubSub, topic(sid), {:active_context, ctx})

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Pure derivation
  # ============================================================================

  @doc """
  Derive an active context map from URL params and full URI.

  Returns:

      %{
        route: "/activities",
        focused_resource: {:request, "req_abc..."},
        params: params
      }

  `route` is the path component of the URI; `focused_resource` is a tagged
  tuple identifying the primary resource the user is currently looking at,
  derived from URL params. Falls back to `nil` when no specific resource
  is in focus (e.g. listing pages without a selection).
  """
  @spec derive(map(), String.t() | nil) :: t()
  def derive(params, uri) when is_map(params) do
    %{
      route: route_from_uri(uri),
      focused_resource: focused_resource_from_params(params),
      params: params,
      snapshot: nil
    }
  end

  def derive(_params, _uri),
    do: %{route: nil, focused_resource: nil, params: %{}, snapshot: nil}

  defp route_from_uri(nil), do: nil

  defp route_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) -> path
      _ -> nil
    end
  end

  # Identify the primary focused resource from URL params. Order matters —
  # most-specific match wins.
  defp focused_resource_from_params(%{"ref" => ref}) when is_binary(ref) and ref != "",
    do: {:component, ref}

  defp focused_resource_from_params(%{"id" => id}) when is_binary(id) and id != "" do
    cond do
      String.starts_with?(id, "req_") -> {:request, id}
      String.starts_with?(id, "exec_") -> {:execution, id}
      String.starts_with?(id, "sched_") -> {:schedule, id}
      true -> {:log, id}
    end
  end

  defp focused_resource_from_params(%{"publisher" => p, "tincture_name" => n})
       when is_binary(p) and is_binary(n),
       do: {:tincture, "#{p}.#{n}"}

  defp focused_resource_from_params(_), do: nil
end
