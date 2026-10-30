# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the chat (`PrismWeb.ChatLive` at `/chat`), with the
  session's athanor selected; or, when this browser session left the
  Canvas mode last, in the Canvas (`PrismWeb.Surface`). A new sign-in is a
  new session, so it lands in the chat.
  """

  use PrismWeb, :live_view

  def mount(_params, session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      athanor ->
        route = Sanctum.Tenancy.Athanors.route_slug(athanor)
        token = session[to_string(CyfrWeb.SignInResponse.session_key())]

        to =
          case PrismWeb.Surface.recall(token) do
            %{surface: "canvas"} -> PrismWeb.Surface.canvas_path(route)
            _dashboard -> PrismWeb.ChatLive.chat_path(route)
          end

        {:ok, push_navigate(socket, to: to)}
    end
  end

  def render(assigns), do: ~H""
end
