# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatRedirectLive do
  @moduledoc """
  `/chat`, the retired chat page's address, forwards to the person's
  desktop (`PrismWeb.DesktopLive`), where the chat is CYFR's own overlay
  beside AQUA's (`PrismWeb.ChatOverlayLive`, its control on the shelf).
  Its query is dropped: the overlay opens from the shelf, never from an
  address.
  """

  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:athanor_route] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      route ->
        {:ok,
         socket |> assign(:overlay, false) |> push_navigate(to: PrismWeb.DesktopLive.path(route))}
    end
  end

  @impl true
  def render(assigns), do: ~H""
end
