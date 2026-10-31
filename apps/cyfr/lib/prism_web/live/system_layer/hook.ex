# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Hook do
  @moduledoc """
  How a view hears its system layer. A view that embeds the layer
  (`<.live_component module={PrismWeb.SystemLayer} …>`) mounts this hook
  (`on_mount PrismWeb.SystemLayer.Hook`), and every report the layer
  sends it, `{:system_layer, id, outcome}`, is handled here and never
  reaches the view's own `handle_info/2`. Each report is taken, in order:

    * relayed — a report on a prompt the view placed for a nested view
      (`PrismWeb.SystemLayer.relay/4`) goes back to that view
      (`PrismWeb.SystemLayer.relayed/2`);
    * the view's own — a report on a prompt the view placed itself and
      follows by its id (a grant it asked for, a recovery or sharing
      prompt) is the view's `c:system_layer_report/3`, when it answers
      `{:noreply, socket}`;
    * the default — every other report is the view's held asks'
      (`PrismWeb.SystemLayer.reported/2`): a change it asked for that was
      confirmed is repeated by the view's `c:system_layer_repeat/4`, and a
      change that ended lets its secret go. A report the view holds
      nothing under, the layer's refusal of a malformed prompt (`id`
      nil) among them, changes nothing and is said nowhere.

  The hook is mounted after `CyfrWeb.ContextGuard`, so the guard's
  freshness rule has run on the view's context before a report can
  repeat a change under it. The layer's id is the view's own choice, in
  the embed; the hook reads no id.
  """

  alias Phoenix.LiveView.Socket
  alias PrismWeb.SystemLayer

  @doc """
  A report on a prompt the view placed and follows itself: `{:noreply,
  socket}` once handled, or `:pass` to leave it to the default. `id` is
  nil for a prompt the layer refused as malformed.
  """
  @callback system_layer_report(id :: String.t() | nil, outcome :: term(), Socket.t()) ::
              {:noreply, Socket.t()} | :pass

  @doc """
  A change the view asked for under `tag` (`PrismWeb.SystemLayer.call/5`)
  was confirmed: the view makes it again, once, through `call/5` with
  the same `tag`.
  """
  @callback system_layer_repeat(tag :: term(), tool :: String.t(), args :: map(), Socket.t()) ::
              {:noreply, Socket.t()}

  @optional_callbacks system_layer_report: 3, system_layer_repeat: 4

  @doc false
  def on_mount(:default, _params, _session, socket),
    do: {:cont, Phoenix.LiveView.attach_hook(socket, __MODULE__, :handle_info, &on_info/2)}

  defp on_info({:system_layer, id, outcome} = report, socket) do
    case SystemLayer.relayed(socket, report) do
      {:relayed, socket} ->
        {:halt, socket}

      :none ->
        case own(socket, id, outcome) do
          {:noreply, socket} -> {:halt, socket}
          :pass -> {:halt, reported(socket, report)}
        end
    end
  end

  defp on_info(_message, socket), do: {:cont, socket}

  defp own(%Socket{view: view} = socket, id, outcome) do
    if function_exported?(view, :system_layer_report, 3),
      do: view.system_layer_report(id, outcome, socket),
      else: :pass
  end

  defp reported(socket, report) do
    case SystemLayer.reported(socket, report) do
      {:ok, socket} ->
        socket

      {:repeat, tag, tool, args, %Socket{view: view} = socket} ->
        # A repeat exists only for a change the view asked for without a
        # form, so the view that asked defines its repeat.
        {:noreply, socket} = view.system_layer_repeat(tag, tool, args, socket)
        socket
    end
  end
end
