# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaRedirectLive do
  @moduledoc """
  `/a/<athanor>/agents` used to be the agents page. The estate's AQUA lives
  at `/a/<athanor>/aqua` now (`PrismWeb.AquaLive`); the old address
  forwards there, query and all.
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
