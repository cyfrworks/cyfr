# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the chat (`PrismWeb.ChatLive` at `/chat`), with the
  session's athanor selected; or, when this browser session left the
  Canvas mode last, in the Canvas (`PrismWeb.Surface`). A new sign-in is a
  new session, so it lands in the chat. A person whose name and recovery
  code are not finished (an enrollment attempt still open, as
  `person.status` lists it) lands on Settings instead, where the identity
  card finishes them; a status that cannot be read lands as above.
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
          cond do
            unfinished?(socket) ->
              PrismWeb.Focus.path(route, "/settings")

            match?(%{surface: "canvas"}, PrismWeb.Surface.recall(token)) ->
              PrismWeb.Surface.canvas_path(route)

            true ->
              PrismWeb.ChatLive.chat_path(route)
          end

        {:ok, push_navigate(socket, to: to)}
    end
  end

  defp unfinished?(socket) do
    case PrismWeb.Ops.call_tool(socket, "person/status", %{}) do
      {:ok, %{kits: kits}} -> Enum.any?(kits, &(&1.kind == "enrollment"))
      _unread -> false
    end
  end

  def render(assigns), do: ~H""
end
