# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatRedirectLive do
  @moduledoc """
  `/a/<athanor>` used to be that athanor's chat. Chat is one global zone
  now (`PrismWeb.ChatLive` at `/chat`), so the old address forwards to it
  with the estate named — and the topic, when the address carried one.
  """

  use PrismWeb, :live_view

  def mount(params, _session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      athanor ->
        {:ok,
         push_navigate(socket,
           to:
             PrismWeb.ChatLive.chat_path(
               Sanctum.Tenancy.Athanors.route_slug(athanor),
               params["c"]
             )
         )}
    end
  end

  def render(assigns), do: ~H""
end
