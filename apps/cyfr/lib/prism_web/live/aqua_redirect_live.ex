# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaRedirectLive do
  @moduledoc """
  Redirects `/a/<athanor>/agents` to `/a/<athanor>/aqua`, preserving the query.
  """

  use PrismWeb, :live_view

  def mount(params, _session, socket) do
    to = PrismWeb.Focus.path(socket.assigns.athanor_route, "/aqua" <> query(params))
    {:ok, push_navigate(socket, to: to)}
  end

  defp query(params) do
    case params |> Map.delete("athanor") |> Enum.sort() do
      [] -> ""
      rest -> "?" <> Plug.Conn.Query.encode(rest)
    end
  end

  def render(assigns), do: ~H""
end
