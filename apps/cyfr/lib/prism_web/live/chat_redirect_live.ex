# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatRedirectLive do
  @moduledoc """
  `/a/<athanor>` used to be that athanor's chat. Chat is one global zone
  now (`PrismWeb.ChatLive` at `/chat`), so the old address forwards to it
  with the estate named first and the rest of the query — the topic, and
  anything else the address carried — kept as it was.
  """

  use PrismWeb, :live_view

  def mount(params, _session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      athanor ->
        {:ok, push_navigate(socket, to: chat_path(athanor, params))}
    end
  end

  # The estate is the path's, so a stray `a` in the query is dropped with
  # the route param; the rest rides along in a stable order, nested keys
  # included.
  defp chat_path(athanor, params) do
    route = Sanctum.Tenancy.Athanors.route_slug(athanor)
    rest = params |> Map.drop(["athanor", "a"]) |> Enum.sort()

    "/chat?" <> Plug.Conn.Query.encode([{"a", route} | rest])
  end

  def render(assigns), do: ~H""
end
