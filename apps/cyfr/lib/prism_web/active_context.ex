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

  ## Wiring

  Hooked via `live_session :on_mount`. Every authenticated LiveView gets
  `socket.assigns.active_context` populated automatically on mount and
  on every subsequent `handle_params`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView

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

  Add to the `:athanor` live_session:

      live_session :athanor,
        on_mount: [
          {PrismWeb.LiveAuth, :require_auth},
          {PrismWeb.Focus, :assign},
          {PrismWeb.ActiveContext, :assign}
        ] do
        ...
      end
  """
  def on_mount(:assign, params, _session, socket) do
    socket =
      socket
      |> assign(:active_context, derive(params, nil))
      |> LiveView.attach_hook(
        :prism_active_context,
        :handle_params,
        &handle_params_hook/3
      )

    {:cont, socket}
  end

  @doc """
  Attach a page snapshot to the active context. A snapshot describes "what
  is currently on screen" — a small list of items the user is looking at,
  so a consumer can reason about the page without making read tool calls.

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

    assign(socket, :active_context, Map.put(current, :snapshot, capped))
  end

  defp handle_params_hook(params, uri, socket) do
    {:cont, assign(socket, :active_context, derive(params, uri))}
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

  # The route is the page within the athanor: `/a/<athanor>` is focus, not
  # place, and is stripped so the agent sees `/activities`, not
  # `/a/home/activities`.
  defp route_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) -> strip_focus(path)
      _ -> nil
    end
  end

  defp strip_focus("/a/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_athanor, page] -> "/" <> page
      [_athanor] -> "/"
    end
  end

  defp strip_focus(path), do: path

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
