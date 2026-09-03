# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the chat (`PrismWeb.ChatLive` at `/chat`), with the
  session's athanor selected.
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      athanor ->
        {:ok,
         push_navigate(socket,
           to: PrismWeb.ChatLive.chat_path(Sanctum.Tenancy.Athanors.route_slug(athanor))
         )}
    end
  end

  def render(assigns), do: ~H""
end
